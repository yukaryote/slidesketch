import SwiftUI
import ImageIO
import zlib
import CryptoKit

struct ImportedBrush: Identifiable, Codable {
    var id: UUID
    var name: String
    var shape: String
    var grain: String?
    var spacing: Double
    var angle: Double
    var followsStroke: Bool
    var minSize: Double
    var pressureSize: Double
    var pressureOpacity: Double
    var opacity: Double
    var size: Double
    var shapeInverted: Bool
    var grainInverted: Bool
    var grainDepth: Double
    var source: ImportedBrushSource?
    var usesPencilApproximation: Bool { source?.pencilApproximation == true }
}

struct ImportedBrushSource: Codable {
    var fingerprint: String
    var setName: String
    var archive: String
    var secondaryArchive: String?
    var missingAssets: [String]
    var pencilApproximation: Bool
    var tilt: ImportedTilt
    var secondaryTilt: ImportedTilt?
    var azimuth: Bool
    var note: String?
}

struct ImportedTilt: Codable {
    var size: Double
    var opacity: Double
    var gradation: Double
    var bleed: Double
    var compression: Double
    // The proprietary angle encoding is retained without assuming a unit.
    var rawAngle: Double
    init(_ metadata: [String: Any]) {
        func n(_ key: String) -> Double { let n = (metadata[key] as? NSNumber)?.doubleValue ?? 0; return n.isFinite ? n : 0 }
        size = n("dynamicsTiltSize"); opacity = n("dynamicsTiltOpacity")
        gradation = n("dynamicsTiltGradation"); bleed = n("dynamicsTiltBleed")
        compression = n("dynamicsTiltCompression"); rawAngle = n("dynamicsTiltAngle")
    }
}

enum BrushImportError: LocalizedError {
    case invalid, unsupported, tooLarge, noShape
    var errorDescription: String? { switch self {
        case .invalid: "This brush archive is damaged or incomplete."
        case .unsupported: "Choose a Procreate .brush or .brushset file."
        case .tooLarge: "This brush archive exceeds the import size limit."
        case .noShape: "This brush uses a built-in Procreate tip that isn't included in the file. Export a brush with its own Shape image."
    } }
}

// Read ZIP entries in memory, with limits and CRC validation. Paths are never extracted to disk.
enum BrushArchive {
    nonisolated static func files(_ data: Data) throws -> [String: Data] {
        guard data.count < 200_000_000, data.count >= 22 else { throw BrushImportError.tooLarge }
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard let end = stride(from: b.count - 22, through: max(0, b.count - 65557), by: -1).first(where: { u32($0) == 0x06054b50 }) else { throw BrushImportError.invalid }
        let count = u16(end + 10); var position = u32(end + 16), total = 0
        guard count <= 4000 else { throw BrushImportError.tooLarge }
        var output: [String: Data] = [:]
        for _ in 0..<count {
            guard position >= 0, position + 46 <= b.count, u32(position) == 0x02014b50 else { throw BrushImportError.invalid }
            let flags = u16(position + 8), method = u16(position + 10), crc = u32(position + 16)
            let compressed = u32(position + 20), size = u32(position + 24), nameLength = u16(position + 28), extra = u16(position + 30), comment = u16(position + 32), local = u32(position + 42)
            guard flags & 1 == 0, size <= 32_000_000, position + 46 + nameLength + extra + comment <= b.count, local + 30 <= b.count else { throw BrushImportError.invalid }
            let name = String(decoding: b[(position + 46)..<(position + 46 + nameLength)], as: UTF8.self)
            position += 46 + nameLength + extra + comment
            guard !name.hasSuffix("/") else { continue }
            total += size; guard total <= 300_000_000 else { throw BrushImportError.tooLarge }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start >= 0, start + compressed <= b.count, u32(local) == 0x04034b50 else { throw BrushImportError.invalid }
            let input = Data(b[start..<(start + compressed)])
            var decoded = Data(count: size)
            if method == 0 { guard compressed == size else { throw BrushImportError.invalid }; decoded = input }
            else if method == 8 {
                var stream = z_stream()
                guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw BrushImportError.invalid }
                let result = decoded.withUnsafeMutableBytes { out in input.withUnsafeBytes { raw -> Int32 in
                    stream.next_in = UnsafeMutablePointer(mutating: raw.bindMemory(to: UInt8.self).baseAddress); stream.avail_in = uInt(compressed)
                    stream.next_out = out.bindMemory(to: UInt8.self).baseAddress; stream.avail_out = uInt(size)
                    return inflate(&stream, Z_FINISH)
                } }
                let actual = stream.total_out; inflateEnd(&stream)
                guard result == Z_STREAM_END, actual == size else { throw BrushImportError.invalid }
            } else { throw BrushImportError.unsupported }
            let actualCRC = decoded.withUnsafeBytes { crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, uInt(size)) }
            guard actualCRC == crc else { throw BrushImportError.invalid }
            output[name] = decoded
        }
        return output
    }
    nonisolated static func metadata(_ data: Data) throws -> [String: Any] {
        let binary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let xml = try PropertyListSerialization.data(fromPropertyList: binary, format: .xml, options: 0)
        // Foundation reconstitutes CF$UID dictionaries as opaque CoreFoundation
        // objects even when parsing XML. Rename that marker before decoding.
        let readable = Data(String(decoding: xml, as: UTF8.self).replacingOccurrences(of: "<key>CF$UID</key>", with: "<key>BrushArchiveUID</key>").utf8)
        guard let plist = try PropertyListSerialization.propertyList(from: readable, options: [], format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any], let props = objects.compactMap({ $0 as? [String: Any] }).first(where: { $0["plotSpacing"] != nil }) else { throw BrushImportError.invalid }
        var result = props
        for key in ["name", "bundledShapePath", "bundledGrainPath"] {
            if let uid = props[key] as? [String: Int], let index = uid["BrushArchiveUID"], objects.indices.contains(index) { result[key] = objects[index] }
        }
        return result
    }
}

extension DeckStore {
    var importedBrushFolder: URL { documents.appendingPathComponent("BrushLibrary", isDirectory: true) }
    var activeImportedBrush: ImportedBrush? { importedBrushes.first { $0.id == (tool == .erase ? importedEraserID : importedBrushID) } }
    // Developer-tool transfers could leave the legacy Brushes folder owned by
    // root. Migrate into app-owned storage, retaining the original unchanged.
    func prepareImportedBrushStorage() throws {
        let fm = FileManager.default, folder = importedBrushFolder
        guard !fm.fileExists(atPath: folder.path) else { return }
        let legacy = documents.appendingPathComponent("Brushes", isDirectory: true)
        guard fm.fileExists(atPath: legacy.path) else {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true); return
        }
        let staging = documents.appendingPathComponent("BrushLibrary-migration-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        do {
            for file in try fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) {
                let destination = staging.appendingPathComponent(file.lastPathComponent)
                try fm.copyItem(at: file, to: destination)
                let attributes = try fm.attributesOfItem(atPath: destination.path)
                let mode = attributes[.type] as? FileAttributeType == .typeDirectory ? 0o700 : 0o600
                try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: destination.path)
            }
            // The app owns both staging and its parent; the legacy directory
            // never needs to be modified or renamed.
            try fm.moveItem(at: staging, to: folder)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
    func loadImportedBrushes() {
        do { try prepareImportedBrushStorage() }
        catch { errorMessage = "Could not prepare brush storage: " + error.localizedDescription }
        let url = importedBrushFolder.appendingPathComponent("Library.json")
        if let bytes = try? Data(contentsOf: url), let brushes = try? JSONDecoder().decode([ImportedBrush].self, from: bytes) { importedBrushes = brushes }
    }
    func importBundledBrushesIfNeeded() async {
        guard let url = Bundle.main.url(forResource: "COFEPencils", withExtension: "brushset") else { return }
        await importBrushes(url, quietly: true)
    }
    func importBrushes(_ url: URL, quietly: Bool = false) async {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard ["brush", "brushset"].contains(url.pathExtension.lowercased()) else { errorMessage = BrushImportError.unsupported.localizedDescription; return }
        do {
            let data = try Data(contentsOf: url)
            let entries = try await Task.detached(priority: .userInitiated) { try BrushArchive.files(data) }.value
            var brushes: [ImportedBrush] = []
            try prepareImportedBrushStorage()
            // Reset snapshots and Sub01 dual components are not standalone brushes.
            let paths = entries.keys.filter { $0.hasSuffix("Brush.archive") && !$0.split(separator: "/").contains(where: { $0 == "Reset" || $0.hasPrefix("Sub") || $0 == "__MACOSX" }) }.sorted()
            for path in paths {
                let prefix = String(path.dropLast("Brush.archive".count))
                let archive = entries[path]!
                let fingerprint = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
                if importedBrushes.contains(where: { $0.source?.fingerprint == fingerprint }) { continue }
                let m = try BrushArchive.metadata(archive)
                let name = m["name"] as? String ?? url.deletingPathExtension().lastPathComponent
                let embeddedShape = entries[prefix + "Shape.png"]
                let pencil = embeddedShape == nil && name.localizedCaseInsensitiveContains("pencil")
                let shape = embeddedShape ?? BrushFallback.shape(pencil: pencil)
                guard let imageSource = CGImageSourceCreateWithData(shape as CFData, nil), CGImageSourceGetCount(imageSource) > 0 else { throw BrushImportError.invalid }
                func number(_ key: String, _ fallback: Double) -> Double { let value = (m[key] as? NSNumber)?.doubleValue ?? fallback; return value.isFinite ? value : fallback }
                func flag(_ key: String) -> Bool { (m[key] as? NSNumber)?.boolValue ?? false }
                let id = UUID(), shapeName = id.uuidString + "-shape.png", grainName = id.uuidString + "-grain.png"
                try shape.write(to: importedBrushFolder.appendingPathComponent(shapeName), options: .atomic)
                let grain = entries[prefix + "Grain.png"]
                if let grain { try grain.write(to: importedBrushFolder.appendingPathComponent(grainName), options: .atomic) }
                let archiveName = id.uuidString + ".archive"
                try archive.write(to: importedBrushFolder.appendingPathComponent(archiveName), options: .atomic)
                let secondary = entries[prefix + "Sub01/Brush.archive"]
                let secondaryName = id.uuidString + "-secondary.archive"
                if let secondary { try secondary.write(to: importedBrushFolder.appendingPathComponent(secondaryName), options: .atomic) }
                var missing: [String] = []
                if embeddedShape == nil { missing.append(m["bundledShapePath"] as? String ?? "Built-in shape") }
                if grain == nil, let grainPath = m["bundledGrainPath"] as? String, grainPath != "$null" { missing.append(grainPath) }
                let source = ImportedBrushSource(fingerprint: fingerprint, setName: url.lastPathComponent == "COFEPencils.brushset" ? "COFE Pencils" : url.deletingPathExtension().lastPathComponent,
                    archive: archiveName, secondaryArchive: secondary == nil ? nil : secondaryName, missingAssets: missing,
                    pencilApproximation: pencil, tilt: ImportedTilt(m), secondaryTilt: try secondary.map { ImportedTilt(try BrushArchive.metadata($0)) }, azimuth: flag("shapeAzimuth"),
                    note: name.localizedCaseInsensitiveContains("smudge") ? "Tip imported; smudging is not supported" : !missing.isEmpty ? "Approximation · built-in Procreate textures unavailable" : secondary != nil ? "Dual-brush mixing approximated" : nil)
                brushes.append(ImportedBrush(id: id, name: name, shape: shapeName, grain: grain == nil ? nil : grainName, spacing: min(2, max(0.006, number("plotSpacing", 0.05))), angle: number("shapeAngle", 0), followsStroke: abs(number("shapeRotation", 0)) > 0.5, minSize: min(1, max(0.01, number("minSize", 0.05))), pressureSize: min(1, max(0, number("dynamicsPressureSize", 1))), pressureOpacity: min(1, max(0, number("dynamicsPressureOpacity", 0))), opacity: min(1, max(0.01, number("paintOpacity", 1))), size: min(100, max(4, number("paintSize", 0.04) * 500)), shapeInverted: flag("shapeInverted"), grainInverted: flag("textureInverted"), grainDepth: min(1, max(0, number("grainDepth", 1))), source: source))
            }
            guard !paths.isEmpty else { throw BrushImportError.invalid }
            guard !brushes.isEmpty else { if !quietly { notify("These brushes are already imported") }; return }
            let library = importedBrushes + brushes
            try JSONEncoder().encode(library).write(to: importedBrushFolder.appendingPathComponent("Library.json"), options: .atomic)
            importedBrushes = library
            if !quietly { notify("Imported \(brushes.count) brushes") }
        } catch { errorMessage = "Could not import brushes: " + error.localizedDescription }
    }
    func chooseImportedBrush(_ brush: ImportedBrush, eraser: Bool) {
        if eraser { importedEraserID = brush.id; eraserSize = brush.size; setTool(.erase) }
        else { importedBrushID = brush.id; brushSize = brush.size; setTool(.draw) }
    }
}

enum BrushFallback {
    static func shape(pencil: Bool) -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 512, height: 512), format: format).image { c in
            UIColor.black.setFill(); c.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
            if pencil {
                let raster = GraphiteStrokeRaster(brush: .graphite, color: "FFFFFF", size: CGSize(width: 512, height: 512))
                raster.add(GraphiteContact(point: CGPoint(x: 256, y: 256), width: 480, pressure: 1, altitude: .pi/2, azimuth: 0))
                if let (image, rect) = raster.snapshot() { UIImage(cgImage: image).draw(in: rect) }
            } else {
                UIColor.white.setFill(); c.cgContext.fillEllipse(in: CGRect(x: 12, y: 12, width: 488, height: 488))
            }
        }.pngData()!
    }
}

@MainActor
enum ImportedBrushTip {
    private static let cache = NSCache<NSString, UIImage>()
    static func image(_ brush: ImportedBrush, folder: URL, color: String) -> CGImage? {
        let key = (brush.id.uuidString + color) as NSString
        if let image = cache.object(forKey: key) { return image.cgImage }
        guard let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(brush.shape) as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary),
              let pixels = FillPixels(image: image), let rgb = UInt32(color, radix: 16) else { return nil }
        var grain: FillPixels?
        if let path = brush.grain, let source = CGImageSourceCreateWithURL(folder.appendingPathComponent(path) as CFURL, nil), let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 256] as CFDictionary) { grain = FillPixels(image: image) }
        var output = pixels.rgba
        for i in stride(from: 0, to: output.count, by: 4) {
            var alpha = Double(pixels.rgba[i]) / 255
            if brush.shapeInverted { alpha = 1 - alpha }
            if let grain {
                let x = (i / 4) % pixels.width, y = (i / 4) / pixels.width
                var texture = Double(grain.rgba[((y % grain.height) * grain.width + x % grain.width) * 4]) / 255
                if brush.grainInverted { texture = 1 - texture }
                alpha *= 1 - brush.grainDepth + brush.grainDepth * texture
            }
            output[i] = UInt8(Double((rgb >> 16) & 255) * alpha); output[i + 1] = UInt8(Double((rgb >> 8) & 255) * alpha); output[i + 2] = UInt8(Double(rgb & 255) * alpha); output[i + 3] = UInt8(alpha * 255)
        }
        let region = FillRegion(bounds: CGRect(x: 0, y: 0, width: pixels.width, height: pixels.height), rgba: output, identity: "tip")
        guard let cg = region.cgImage else { return nil }
        cache.countLimit = 40; cache.setObject(UIImage(cgImage: cg), forKey: key); return cg
    }
}

final class StampStrokeView: UIView {
    var brush: ImportedBrush?
    var tip: CGImage?
    var context: CGContext?
    var previous: CGPoint?
    var previousPressure = 1.0
    var width = 30.0
    var inkOpacity = 1.0
    var touchedBounds = CGRect.null
    var distanceToNext = 0.0
    var canvasSize = PresentationDimensions.standard.size
    var pencilRaster: GraphiteStrokeRaster?
    func begin(brush: ImportedBrush, tip: CGImage, width: Double, opacity: Double, color: String = "FFFFFF", canvasSize: CGSize = PresentationDimensions.standard.size) {
        self.brush = brush; self.tip = tip; self.width = width; inkOpacity = opacity; self.canvasSize = canvasSize
        context = brush.usesPencilApproximation ? nil : CGContext(data: nil, width: Int(canvasSize.width), height: Int(canvasSize.height), bitsPerComponent: 8, bytesPerRow: Int(canvasSize.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.translateBy(x: 0, y: canvasSize.height); context?.scaleBy(x: 1, y: -1)
        pencilRaster = brush.usesPencilApproximation ? GraphiteStrokeRaster(brush: brush.name.hasSuffix("- F") ? .pencil : .graphite, color: color, size: canvasSize, grainDepth: brush.grainDepth) : nil
        previous = nil; touchedBounds = .null; distanceToNext = 0; isHidden = false
    }
    func add(_ point: CGPoint, pressure: Double, tilt: Double, azimuth: Double = 0) {
        guard let brush, let tip else { return }
        let pressure = min(1, max(0, pressure))
        let dynamics = brush.source?.tilt
        if let pencilRaster {
            var contact = GraphiteContact(point: point, width: width, pressure: pressure, altitude: tilt, azimuth: azimuth, opacity: inkOpacity * brush.opacity,
                tiltSize: dynamics?.size ?? 0.66, pressureSize: brush.pressureSize, pressureOpacity: brush.pressureOpacity, tiltOpacity: dynamics?.opacity ?? 0.2,
                gradation: min(1, (dynamics?.gradation ?? 0.2) * 4), compression: dynamics?.compression ?? 1)
            if brush.source?.azimuth != true { contact.angle = 0 }
            pencilRaster.add(contact); setNeedsDisplay(); return
        }
        guard let context else { return }
        let shade = min(1, max(0, (.pi/3 - tilt) / (.pi/6)))
        let size = max(1, width * max(brush.minSize, 1 - brush.pressureSize + brush.pressureSize * pressure) * (1 + shade * (dynamics?.size ?? 0.1) * 6))
        let spacing = max(0.6, size * brush.spacing)
        let start = previous ?? point, distance = Geometry.distance(start, point)
        let angle = brush.angle + (brush.source?.azimuth == true ? azimuth : 0) + (brush.followsStroke && distance > 0 ? atan2(point.y - start.y, point.x - start.x) : 0)
        func stamp(_ p: CGPoint) {
            context.saveGState(); context.translateBy(x: p.x, y: p.y); context.rotate(by: angle)
            context.setAlpha(inkOpacity * brush.opacity * (1 - brush.pressureOpacity + brush.pressureOpacity * pressure) * (1 - shade * (dynamics?.opacity ?? 0)))
            context.scaleBy(x: 1, y: -1)
            context.draw(tip, in: CGRect(x: -size / 2, y: -size / 2, width: size, height: size))
            context.restoreGState()
            touchedBounds = touchedBounds.union(CGRect(x: p.x - size, y: p.y - size, width: size * 2, height: size * 2))
        }
        if previous == nil { stamp(point); distanceToNext = spacing }
        else if distance > 0 {
            var traveled = distanceToNext
            while traveled <= distance { let t = traveled / distance; stamp(CGPoint(x: start.x + (point.x - start.x) * t, y: start.y + (point.y - start.y) * t)); traveled += spacing }
            distanceToNext = traveled - distance
        }
        previous = point; previousPressure = pressure; setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        if let (image, bounds) = pencilRaster?.snapshot() { UIImage(cgImage: image).draw(in: bounds); return }
        guard let image = context?.makeImage(), let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.translateBy(x: 0, y: canvasSize.height); ctx.scaleBy(x: 1, y: -1); ctx.draw(image, in: bounds)
    }
    func result() -> (CGImage, CGRect)? {
        if let pencilRaster { pencilRaster.finish(); return pencilRaster.snapshot() }
        let crop = touchedBounds.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !crop.isEmpty, !crop.isNull, let image = context?.makeImage()?.cropping(to: crop) else { return nil }
        return (image, crop)
    }
    func clear() { pencilRaster = nil; brush = nil; tip = nil; context = nil; previous = nil; isHidden = true; setNeedsDisplay() }
}
