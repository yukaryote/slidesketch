import SwiftUI
import CoreGraphics
import Combine
import CryptoKit

// Pixel data is copied before leaving the main actor; filling never reads live views.
struct FillPixels: Sendable {
    let width: Int
    let height: Int
    let rgba: [UInt8]
    nonisolated init?(image: CGImage) {
        width = image.width; height = image.height
        guard width > 0, height > 0, width <= 4000, height <= 4000 else { return nil }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let success = bytes.withUnsafeMutableBytes { data -> Bool in
            guard let context = CGContext(data: data.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard success else { return nil }; rgba = bytes
    }
    nonisolated func alpha(at point: CGPoint) -> UInt8 {
        let x = min(width - 1, max(0, Int(point.x))), y = min(height - 1, max(0, Int(point.y)))
        return rgba[(y * width + x) * 4 + 3]
    }
}

struct FillRegion: Sendable {
    let bounds: CGRect
    let rgba: [UInt8]
    let identity: String
    nonisolated var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else { return nil }
        return CGImage(width: Int(bounds.width), height: Int(bounds.height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(bounds.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

enum ColorFillEngine {
    // A scanline flood fill keeps work proportional to the connected region.
    nonisolated static func fill(_ pixels: FillPixels, at point: CGPoint, hex: String, threshold: Double, expandEdges: Bool) -> FillRegion? {
        let w = pixels.width, h = pixels.height
        guard point.x.isFinite, point.y.isFinite, point.x >= 0, point.y >= 0, point.x < Double(w), point.y < Double(h), let color = UInt32(hex, radix: 16) else { return nil }
        let start = Int(point.y) * w + Int(point.x)
        let target = Array(pixels.rgba[(start * 4)..<(start * 4 + 4)])
        let tolerance = Int(min(1, max(0, threshold)) * 255)
        var mask = [UInt8](repeating: 0, count: w * h)
        var pending = [start]
        var minX = w, minY = h, maxX = 0, maxY = 0
        func matches(_ index: Int) -> Bool {
            let p = index * 4
            return abs(Int(pixels.rgba[p]) - Int(target[0])) <= tolerance && abs(Int(pixels.rgba[p + 1]) - Int(target[1])) <= tolerance && abs(Int(pixels.rgba[p + 2]) - Int(target[2])) <= tolerance && abs(Int(pixels.rgba[p + 3]) - Int(target[3])) <= tolerance
        }
        while let seed = pending.popLast() {
            if mask[seed] != 0 { continue }
            let y = seed / w
            var left = seed % w
            while left > 0 && mask[y * w + left - 1] == 0 && matches(y * w + left - 1) { left -= 1 }
            var x = left, above = false, below = false
            while x < w && mask[y * w + x] == 0 && matches(y * w + x) {
                let p = y * w + x; mask[p] = 1
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if y > 0 {
                    let eligible = mask[p - w] == 0 && matches(p - w)
                    if eligible && !above { pending.append(p - w) }; above = eligible
                }
                if y + 1 < h {
                    let eligible = mask[p + w] == 0 && matches(p + w)
                    if eligible && !below { pending.append(p + w) }; below = eligible
                }
                x += 1
            }
        }
        guard minX <= maxX, minY <= maxY else { return nil }
        // Extend one pixel underneath antialiased ink, without opening another flood path.
        if expandEdges { minX = max(0, minX - 1); minY = max(0, minY - 1); maxX = min(w - 1, maxX + 1); maxY = min(h - 1, maxY + 1) }
        let width = maxX - minX + 1, height = maxY - minY + 1
        var output = [UInt8](repeating: 0, count: width * height * 4)
        for y in minY...maxY {
            for x in minX...maxX {
                let p = y * w + x
                let edge = expandEdges && ((x > 0 && mask[p - 1] == 1) || (x + 1 < w && mask[p + 1] == 1) || (y > 0 && mask[p - w] == 1) || (y + 1 < h && mask[p + w] == 1))
                guard mask[p] == 1 || edge else { continue }
                let q = ((y - minY) * width + x - minX) * 4
                output[q] = UInt8((color >> 16) & 255); output[q + 1] = UInt8((color >> 8) & 255); output[q + 2] = UInt8(color & 255); output[q + 3] = 255
            }
        }
        return FillRegion(bounds: CGRect(x: minX, y: minY, width: width, height: height), rgba: output, identity: "\(w)x\(h):" + SHA256.hash(data: Data(mask)).map { String(format: "%02x", $0) }.joined())
    }
}

extension DeckStore {
    var referenceLayer: StudioLayer? { layers.first { $0.id == slide.referenceLayerID } }
    func toggleReference(_ layer: StudioLayer) {
        guard layers.contains(where: { $0.id == layer.id }) else { return }
        checkpoint(); deck.slides[active].referenceLayerID = slide.referenceLayerID == layer.id ? nil : layer.id; save()
    }
    func layerPixels(_ layer: StudioLayer) -> FillPixels? {
        let renderer = ImageRenderer(content: LayerElements(slide: slide, layer: layer, store: self).compositingGroup().environment(\.colorScheme, .light))
        renderer.scale = 1
        guard let image = renderer.uiImage?.cgImage else { return nil }
        return FillPixels(image: image)
    }
    func boundaryElements(in layer: StudioLayer) -> [SlideElement] {
        slide.elements.filter { element in
            element.layerID == layer.id && (element.kind == .ink || element.kind == .erase || element.kind == .artwork || (slide.referenceLayerID == layer.id && element.kind == .image))
        }
    }
    func colorDrop(at point: CGPoint) {
        guard !isFilling else { return }
        guard canEditActiveLayer else { notify("Choose a visible, unlocked layer"); return }
        guard point.x >= 0, point.y >= 0, point.x < canvasSize.width, point.y < canvasSize.height else { return }
        canvasCommands.send(.finishStroke)
        let sourceLayer = referenceLayer ?? activeLayer
        let boundaries = boundaryElements(in: sourceLayer)
        let cache = fillCache
        let cached = cache.slideID == slide.id && cache.layerID == sourceLayer.id && cache.elements == boundaries && cache.pixels?.width == Int(canvasSize.width) && cache.pixels?.height == Int(canvasSize.height) ? cache.pixels : nil
        let atoms = cached == nil ? DrawingRasterizer.atoms(boundaries, store: self, linework: true) : []
        let slideID = slide.id, layerID = activeLayer.id, revision = deckRevision
        let color = pickerColor, threshold = fillThreshold, canvasSize = canvasSize
        isFilling = true; canvasInteraction.send()
        Task {
            let output = await Task.detached(priority: .userInitiated) { () -> (FillPixels, FillRegion, Data)? in
                guard let source = cached ?? DrawingRasterizer.render(atoms, size: canvasSize, canvasSize: canvasSize).flatMap({ FillPixels(image: $0) }),
                      let region = ColorFillEngine.fill(source, at: point, hex: color, threshold: threshold, expandEdges: true),
                      let image = region.cgImage, let png = DrawingRasterizer.png(image) else { return nil }
                return (source, region, png)
            }.value
            defer { isFilling = false }
            guard deckRevision == revision, slide.id == slideID, activeLayer.id == layerID else { notify("Fill canceled after the canvas changed"); return }
            guard let (source, region, png) = output else { return }
            cache.slideID = slideID; cache.layerID = sourceLayer.id; cache.elements = boundaries; cache.pixels = source
            do { try commitColorFill(region, layerID: layerID, behind: true, png: png); notify("ColorDrop") }
            catch { errorMessage = "Could not save the color fill: " + error.localizedDescription }
        }
    }
    func commitColorFill(_ region: FillRegion, layerID: UUID, behind: Bool, png: Data? = nil) throws {
        guard let layer = layers.first(where: { $0.id == layerID }), layer.visible, !layer.locked,
              let data = png ?? region.cgImage.flatMap({ DrawingRasterizer.png($0) }) else { return }
        let filename = UUID().uuidString + ".png"
        try data.write(to: mediaFolder.appendingPathComponent(filename), options: .atomic)
        checkpoint()
        let bounds = region.bounds
        let matches = slide.elements.filter { $0.kind == .fill && $0.layerID == layerID && $0.fillRegionID == region.identity && $0.rotation == 0 && $0.flipX != true && $0.flipY != true && abs($0.x - bounds.minX) <= 1 && abs($0.y - bounds.minY) <= 1 && abs($0.width - bounds.width) <= 2 && abs($0.height - bounds.height) <= 2 }
        if var existing = matches.first {
            existing.asset = filename; existing.x = bounds.minX; existing.y = bounds.minY; existing.width = bounds.width; existing.height = bounds.height
            update(existing)
            let duplicates = Set(matches.dropFirst().map(\.id))
            deck.slides[active].elements.removeAll { duplicates.contains($0.id) }
        } else {
            deck.slides[active].elements.append(SlideElement(kind: .fill, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height, asset: filename, name: "Color fill", layerID: layerID, fillBehind: behind, fillRegionID: region.identity))
        }
        selected = nil; save()
    }
}

struct ColorDropControl: View {
    @ObservedObject var store: DeckStore
    var canvasFrame: CGRect
    var visibleFrame: CGRect
    @Binding var dropPosition: CGPoint?
    @Binding var thresholdActive: Bool
    var onTap: () -> Void
    @State private var holdWork: DispatchWorkItem?
    @State private var holdPoint: CGPoint?
    @State private var seed: CGPoint?
    @State private var thresholdX: Double = 0
    @State private var startThreshold: Double = 0
    @GestureState private var dragging = false

    var body: some View {
        Circle().fill(Color(hex: store.pickerColor)).overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 1.5)).frame(width: 29, height: 29).frame(width: 48, height: 48)
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .highPriorityGesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("editor-space"))
                .updating($dragging) { _, state, _ in state = true }
                .onChanged { event in
                    guard !store.isFilling else { return }
                    if dropPosition == nil { store.canvasInteraction.send() }
                    dropPosition = event.location
                    if thresholdActive {
                        store.fillThreshold = min(0.97, max(0.01, startThreshold + (event.location.x - thresholdX) / 280))
                    } else if canvasFrame.intersection(visibleFrame).contains(event.location) {
                        if holdPoint == nil || Geometry.distance(holdPoint!, event.location) > 5 {
                            holdWork?.cancel(); holdPoint = event.location
                            let location = event.location
                            let task = DispatchWorkItem {
                                guard dropPosition != nil else { return }
                                seed = canvasPoint(location); thresholdX = location.x; startThreshold = store.fillThreshold; thresholdActive = true
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                            holdWork = task; DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: task)
                        }
                    } else { holdWork?.cancel(); holdPoint = nil }
                }
                .onEnded { event in
                    let target = thresholdActive ? seed : canvasFrame.intersection(visibleFrame).contains(event.location) ? canvasPoint(event.location) : nil
                    clearDrag()
                    if let target { store.colorDrop(at: target) }
                })
            .onChange(of: dragging) { if !dragging { clearDrag() } }
            .onDisappear { clearDrag() }
            .accessibilityLabel("Colors").accessibilityHint("Tap to choose a color. Drag onto the canvas to fill an area.")
            .accessibilityAddTraits(.isButton).accessibilityAction { onTap() }
    }
    private func canvasPoint(_ point: CGPoint) -> CGPoint {
        CanvasViewportGeometry.canvasPoint(point, in: canvasFrame, canvasSize: store.canvasSize)
    }
    private func clearDrag() { holdWork?.cancel(); holdWork = nil; holdPoint = nil; seed = nil; dropPosition = nil; thresholdActive = false }
}
