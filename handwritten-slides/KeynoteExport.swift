import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import Combine

// A standard, uncompressed ZIP container keeps this exporter self-contained on iPad.
enum PresentationZIP {
    nonisolated static func archive(_ files: [(String, Data)]) -> Data {
        func u16(_ n: Int) -> Data { var v = UInt16(n).littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        func u32(_ n: UInt32) -> Data { var v = n.littleEndian; return withUnsafeBytes(of: &v) { Data($0) } }
        let table: [UInt32] = (0..<256).map { i in var c = UInt32(i); for _ in 0..<8 { c = c & 1 != 0 ? 0xedb88320 ^ (c >> 1) : c >> 1 }; return c }
        func crc(_ bytes: Data) -> UInt32 { var c: UInt32 = 0xffffffff; for byte in bytes { c = table[Int((c ^ UInt32(byte)) & 255)] ^ (c >> 8) }; return c ^ 0xffffffff }
        var data = Data(), central = Data()
        for (path, bytes) in files {
            let name = Data(path.utf8), checksum = crc(bytes), offset = UInt32(data.count), count = UInt32(bytes.count)
            [u32(0x04034b50), u16(20), u16(0), u16(0), u16(0), u16(33), u32(checksum), u32(count), u32(count), u16(name.count), u16(0), name, bytes].forEach { data.append($0) }
            [u32(0x02014b50), u16(20), u16(20), u16(0), u16(0), u16(0), u16(33), u32(checksum), u32(count), u32(count), u16(name.count), u16(0), u16(0), u16(0), u16(0), u32(0), u32(offset), name].forEach { central.append($0) }
        }
        let offset = UInt32(data.count); data += central
        [u32(0x06054b50), u16(0), u16(0), u16(files.count), u16(files.count), u32(UInt32(central.count)), u32(offset), u16(0)].forEach { data.append($0) }
        return data
    }
}

nonisolated struct PresentationText: Sendable {
    var value: String
    var font: String
    var size: Double
    var color: String
    var bold = false
    var italic = false
}

nonisolated struct PresentationPart: Sendable {
    var data = Data()
    var ext = "png"
    var poster: Data? = nil
    var rect = CGRect(x: 0, y: 0, width: 1600, height: 900)
    var rotation = 0.0
    var flipX = false
    var flipY = false
    var opacity = 1.0
    var options: VideoOptions? = nil
    var name = "Artwork"
    var text: PresentationText? = nil
}
nonisolated struct PresentationSlide: Sendable { var paper: String; var parts: [PresentationPart] }

enum KeynoteExporter {
    // Tight artwork bounds keep invisible, slide-sized pictures from intercepting
    // clicks on the independently editable media underneath them in PowerPoint.
    nonisolated static func artworkPart(_ image: CGImage) throws -> PresentationPart? {
        guard let pixels = FillPixels(image: image) else { throw CocoaError(.fileWriteUnknown) }
        var left = pixels.width, top = pixels.height, right = -1, bottom = -1
        for y in 0..<pixels.height {
            for x in 0..<pixels.width where pixels.rgba[(y * pixels.width + x) * 4 + 3] != 0 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left, bottom >= top else { return nil }
        let bounds = CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
        guard let cropped = image.cropping(to: bounds), let png = DrawingRasterizer.png(cropped) else { throw CocoaError(.fileWriteUnknown) }
        return PresentationPart(data: png, rect: bounds, name: "Drawing")
    }

    nonisolated static func makePresentation(slides content: [PresentationSlide], theme: Data, canvasSize: CGSize = PresentationDimensions.standard.size) -> Data {
        let p = "http://schemas.openxmlformats.org/presentationml/2006/main", a = "http://schemas.openxmlformats.org/drawingml/2006/main", r = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
        func attribute(_ value: String) -> String {
            // XML 1.0 excludes some control characters that can arrive through pasted text.
            let valid = String(value.unicodeScalars.filter { scalar in
                let v = scalar.value
                return v == 9 || v == 10 || v == 13 || (32...0xD7FF).contains(v) || (0xE000...0xFFFD).contains(v) || (0x10000...0x10FFFF).contains(v)
            })
            return valid.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&apos;")
        }
        func xml(_ s: String) -> Data { Data(("<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>" + s).utf8) }
        func rels(_ body: String) -> Data { xml("<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(body)</Relationships>") }
        func relation(_ id: String, _ type: String, _ target: String) -> String { "<Relationship Id=\"\(id)\" Type=\"\(r)/\(type)\" Target=\"\(target)\"/>" }
        let group = "<p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"0\" cy=\"0\"/><a:chOff x=\"0\" y=\"0\"/><a:chExt cx=\"0\" cy=\"0\"/></a:xfrm></p:grpSpPr>"
        let ns = "xmlns:p=\"\(p)\" xmlns:a=\"\(a)\" xmlns:r=\"\(r)\""
        var files: [(String, Data)] = []
        var overrides = "<Override PartName=\"/ppt/presentation.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml\"/><Override PartName=\"/ppt/slideMasters/slideMaster1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml\"/><Override PartName=\"/ppt/slideLayouts/slideLayout1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml\"/>"
        var slides = "", relationships = relation("master", "slideMaster", "slideMasters/slideMaster1.xml")
        for (index, slide) in content.enumerated() {
            let n = index + 1
            slides += "<p:sldId id=\"\(255 + n)\" r:id=\"s\(n)\"/>"
            relationships += relation("s\(n)", "slide", "slides/slide\(n).xml")
            overrides += "<Override PartName=\"/ppt/slides/slide\(n).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.presentationml.slide+xml\"/>"
            var shapes = "", slideRelationships = relation("layout", "slideLayout", "../slideLayouts/slideLayout1.xml"), timing = ""
            for (partIndex, part) in slide.parts.enumerated() {
                let id = partIndex + 2, key = "s\(n)p\(partIndex)", imageID = "image\(partIndex)", isVideo = part.poster != nil
                func emu(_ value: Double) -> Int { Int((value * 7620).rounded()) }
                let transform = "<a:xfrm rot=\"\(Int(part.rotation * 60000))\" flipH=\"\(part.flipX ? 1 : 0)\" flipV=\"\(part.flipY ? 1 : 0)\"><a:off x=\"\(emu(part.rect.minX))\" y=\"\(emu(part.rect.minY))\"/><a:ext cx=\"\(emu(part.rect.width))\" cy=\"\(emu(part.rect.height))\"/></a:xfrm>"
                if let text = part.text {
                    // A canvas unit is 7620 EMU, or 0.6 typographic points. DrawingML
                    // stores text sizes in hundredths of a point, hence the factor 60.
                    let size = Int((text.size * 60).rounded())
                    let color = text.color.count == 6 && text.color.allSatisfy(\.isHexDigit) ? text.color : "24483E"
                    let alpha = "<a:alpha val=\"\(Int((min(1, max(0, part.opacity)) * 100000).rounded()))\"/>"
                    let style = "sz=\"\(size)\" b=\"\(text.bold ? 1 : 0)\" i=\"\(text.italic ? 1 : 0)\""
                    let font = "<a:solidFill><a:srgbClr val=\"\(color)\">\(alpha)</a:srgbClr></a:solidFill><a:latin typeface=\"\(attribute(text.font))\"/>"
                    let value = text.value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
                    let paragraphs = value.components(separatedBy: "\n").map { line in
                        let run = line.isEmpty ? "" : "<a:r><a:rPr \(style)>\(font)</a:rPr><a:t xml:space=\"preserve\">\(attribute(line))</a:t></a:r>"
                        return "<a:p><a:pPr marL=\"0\" marR=\"0\" indent=\"0\" algn=\"l\"><a:lnSpc><a:spcPct val=\"100000\"/></a:lnSpc><a:spcBef><a:spcPts val=\"0\"/></a:spcBef><a:spcAft><a:spcPts val=\"0\"/></a:spcAft><a:buNone/></a:pPr>\(run)<a:endParaRPr \(style)>\(font)</a:endParaRPr></a:p>"
                    }.joined()
                    shapes += "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(attribute(part.name)) \(id)\"/><p:cNvSpPr txBox=\"1\"/><p:nvPr/></p:nvSpPr><p:spPr>\(transform)<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom><a:noFill/><a:ln><a:noFill/></a:ln></p:spPr><p:txBody><a:bodyPr wrap=\"square\" lIns=\"0\" tIns=\"0\" rIns=\"0\" bIns=\"0\" anchor=\"t\"><a:noAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>"
                    continue
                }
                let imageExt = isVideo ? "png" : part.ext
                files.append(("ppt/media/\(key).\(imageExt)", part.poster ?? part.data))
                slideRelationships += relation(imageID, "image", "../media/\(key).\(imageExt)")
                var media = "", click = ""
                if isVideo {
                    files.append(("ppt/media/\(key).\(part.ext)", part.data))
                    slideRelationships += relation("video\(partIndex)", "video", "../media/\(key).\(part.ext)")
                    slideRelationships += "<Relationship Id=\"media\(partIndex)\" Type=\"http://schemas.microsoft.com/office/2007/relationships/media\" Target=\"../media/\(key).\(part.ext)\"/>"
                    media = "<a:videoFile r:link=\"video\(partIndex)\"/><p:extLst><p:ext uri=\"{DAA4B4D4-6D71-4841-9C94-3DE7FCFB9230}\"><p14:media xmlns:p14=\"http://schemas.microsoft.com/office/powerpoint/2010/main\" r:embed=\"media\(partIndex)\"/></p:ext></p:extLst>"
                    click = "<a:hlinkClick r:id=\"\" action=\"ppaction://media\"/>"
                    let options = part.options
                    let condition = options?.autoplay == true ? "<p:cond delay=\"0\"/>" : "<p:cond evt=\"onClick\" delay=\"0\"><p:tgtEl><p:spTgt spid=\"\(id)\"/></p:tgtEl></p:cond>"
                    timing += "<p:video><p:cMediaNode vol=\"\(options?.muted == true ? 0 : 100000)\"><p:cTn id=\"\(id)\" fill=\"hold\" display=\"0\" spd=\"\(Int((options?.speed ?? 1) * 100000))\"\(options?.loop == true ? " repeatCount=\"indefinite\"" : "")><p:stCondLst>\(condition)</p:stCondLst></p:cTn><p:tgtEl><p:spTgt spid=\"\(id)\"/></p:tgtEl></p:cMediaNode></p:video>"
                }
                let alpha = part.opacity < 1 ? "<a:alphaModFix amt=\"\(Int(part.opacity * 100000))\"/>" : ""
                shapes += "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"\(attribute(part.name)) \(id)\">\(click)</p:cNvPr><p:cNvPicPr/><p:nvPr>\(media)</p:nvPr></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(imageID)\">\(alpha)</a:blip><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr>\(transform)<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
            }
            let timingXML = timing.isEmpty ? "" : "<p:timing><p:tnLst><p:par><p:cTn id=\"1\" dur=\"indefinite\" restart=\"never\" nodeType=\"tmRoot\"><p:childTnLst>\(timing)</p:childTnLst></p:cTn></p:par></p:tnLst></p:timing>"
            let paper = slide.paper.count == 6 && slide.paper.allSatisfy({ $0.isHexDigit }) ? slide.paper : "FFFFFF"
            files.append(("ppt/slides/slide\(n).xml", xml("<p:sld \(ns)><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"\(paper)\"/></a:solidFill><a:effectLst/></p:bgPr></p:bg><p:spTree>\(group)\(shapes)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr>\(timingXML)</p:sld>")))
            files.append(("ppt/slides/_rels/slide\(n).xml.rels", rels(slideRelationships)))
        }
        files.append(("ppt/theme/theme1.xml", theme))
        overrides += "<Override PartName=\"/ppt/theme/theme1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.theme+xml\"/>"
        files.append(("[Content_Types].xml", xml("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Default Extension=\"png\" ContentType=\"image/png\"/><Default Extension=\"gif\" ContentType=\"image/gif\"/><Default Extension=\"jpg\" ContentType=\"image/jpeg\"/><Default Extension=\"jpeg\" ContentType=\"image/jpeg\"/><Default Extension=\"mp4\" ContentType=\"video/mp4\"/><Default Extension=\"m4v\" ContentType=\"video/mp4\"/><Default Extension=\"mov\" ContentType=\"video/quicktime\"/>\(overrides)</Types>")))
        files.append(("_rels/.rels", rels(relation("presentation", "officeDocument", "ppt/presentation.xml"))))
        files.append(("ppt/presentation.xml", xml("<p:presentation \(ns)><p:sldMasterIdLst><p:sldMasterId id=\"2147483648\" r:id=\"master\"/></p:sldMasterIdLst><p:sldIdLst>\(slides)</p:sldIdLst><p:sldSz cx=\"\(Int(canvasSize.width * 7620))\" cy=\"\(Int(canvasSize.height * 7620))\" type=\"custom\"/><p:notesSz cx=\"6858000\" cy=\"9144000\"/></p:presentation>")))
        files.append(("ppt/_rels/presentation.xml.rels", rels(relationships)))
        let colorMap = "<p:clrMap accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" bg1=\"lt1\" bg2=\"lt2\" folHlink=\"folHlink\" hlink=\"hlink\" tx1=\"dk1\" tx2=\"dk2\"/>"
        files.append(("ppt/slideMasters/slideMaster1.xml", xml("<p:sldMaster \(ns)><p:cSld><p:spTree>\(group)</p:spTree></p:cSld>\(colorMap)<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"layout\"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle/><p:bodyStyle/><p:otherStyle/></p:txStyles></p:sldMaster>")))
        files.append(("ppt/slideMasters/_rels/slideMaster1.xml.rels", rels(relation("layout", "slideLayout", "../slideLayouts/slideLayout1.xml") + relation("theme", "theme", "../theme/theme1.xml"))))
        files.append(("ppt/slideLayouts/slideLayout1.xml", xml("<p:sldLayout \(ns) type=\"blank\" preserve=\"1\"><p:cSld name=\"Blank\"><p:spTree>\(group)</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")))
        files.append(("ppt/slideLayouts/_rels/slideLayout1.xml.rels", rels(relation("master", "slideMaster", "../slideMasters/slideMaster1.xml"))))
        return PresentationZIP.archive(files)
    }
}

extension DeckStore {
    func exportKeynote() async throws -> Data {
        canvasCommands.send(.finishStroke)
        let slides = deck.slides, canvasSize = canvasSize
        guard let themeURL = Bundle.main.url(forResource: "ExportTheme", withExtension: "xml") else { throw CocoaError(.fileReadNoSuchFile) }
        let theme = try Data(contentsOf: themeURL)
        var output: [PresentationSlide] = []
        for slide in slides {
            var parts: [PresentationPart] = []
            for layer in slide.layers ?? [] where layer.visible {
                var batch: [SlideElement] = []
                func flush() async throws {
                    guard !batch.isEmpty else { return }
                    var piece = slide; piece.elements = batch
                    let renderer = ImageRenderer(content: LayerElements(slide: piece, layer: layer, store: self, exportCanvasSize: canvasSize).compositingGroup().opacity(layer.opacity).environment(\.colorScheme, .light)); renderer.scale = 1
                    guard let image = renderer.uiImage?.cgImage else { throw CocoaError(.fileWriteUnknown) }
                    if let part = try await Task.detached(priority: .userInitiated, operation: { try KeynoteExporter.artworkPart(image) }).value { parts.append(part) }
                    batch = []
                }
                for element in slide.elements where element.layerID == layer.id {
                    if element.kind == .text {
                        try await flush()
                        let font = UIFont(name: element.font, size: element.fontSize) ?? UIFont.systemFont(ofSize: element.fontSize)
                        let traits = font.fontDescriptor.symbolicTraits
                        let text = PresentationText(value: element.text, font: font.familyName, size: element.fontSize, color: element.color, bold: traits.contains(.traitBold), italic: traits.contains(.traitItalic))
                        parts.append(PresentationPart(rect: CGRect(x: element.x, y: element.y, width: element.width, height: element.height), rotation: element.rotation, flipX: element.flipX == true, flipY: element.flipY == true, opacity: layer.opacity, name: "Text — \(element.name)", text: text))
                        continue
                    }
                    let url = element.asset.flatMap(assetURL)
                    // Every imported image (including GIF) and video is a native,
                    // ungrouped media shape. Flush at each boundary to retain z-order.
                    if element.kind == .video || element.kind == .image {
                        try await flush()
                        guard let url else { throw CocoaError(.fileReadNoSuchFile) }
                        var bytes = try Data(contentsOf: url)
                        var ext = url.pathExtension.lowercased()
                        var poster: Data?
                        if element.kind == .video {
                            guard ["mp4", "m4v", "mov"].contains(ext) else { throw CocoaError(.fileReadUnsupportedScheme) }
                            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true
                            let frame = try await generator.image(at: .zero)
                            poster = DrawingRasterizer.png(frame.image)
                            guard poster != nil else { throw CocoaError(.fileReadCorruptFile) }
                        } else if !["png", "jpg", "jpeg", "gif"].contains(ext) {
                            // Older/imported decks may contain formats Office cannot open.
                            // Convert only those formats, retaining their original resolution.
                            guard let image = ImportedImage(data: bytes) else { throw CocoaError(.fileReadCorruptFile) }
                            bytes = image.data; ext = image.fileExtension
                        }
                        let kind = element.kind == .video ? "Video" : ext == "gif" ? "Animated GIF" : "Image"
                        parts.append(PresentationPart(data: bytes, ext: ext, poster: poster, rect: CGRect(x: element.x, y: element.y, width: element.width, height: element.height), rotation: element.rotation, flipX: element.flipX == true, flipY: element.flipY == true, opacity: layer.opacity, options: element.videoOptions, name: "\(kind) — \(element.name)"))
                    } else { batch.append(element) }
                }
                try await flush()
            }
            output.append(PresentationSlide(paper: slide.paper, parts: parts))
        }
        return await Task.detached(priority: .userInitiated) { KeynoteExporter.makePresentation(slides: output, theme: theme, canvasSize: canvasSize) }.value
    }
}

struct KeynoteExportModifier: ViewModifier {
    @ObservedObject var store: DeckStore
    @Binding var showKeynoteInfo: Bool
    var onExport: (Data) -> Void
    @State private var exportingKeynote = false
    func body(content: Content) -> some View {
        content
        .alert("Export for Keynote", isPresented: $showKeynoteInfo) {
            Button("Cancel", role: .cancel) {}
            Button("Export .pptx") {
                exportingKeynote = true
                Task {
                    defer { exportingKeynote = false }
                    do { onExport(try await store.exportKeynote()) }
                    catch { store.errorMessage = error.localizedDescription }
                }
            }
        } message: { Text("Exports a PowerPoint file you can open in Keynote. Text, images, GIFs, and videos remain separate editable objects. Drawings become images. Fonts may be substituted if unavailable on the other device. Check playback settings after opening in Keynote. Your editable deck stays unchanged.") }
        .overlay { if exportingKeynote { ProgressView("Exporting…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
    }
}
