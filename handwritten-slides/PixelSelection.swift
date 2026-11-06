import SwiftUI
import CoreGraphics

struct PixelCut: @unchecked Sendable {
    var remaining: Data
    var selected: Data
    var remainingLinework: Data
    var selectedLinework: Data
    var bounds: CGRect
}

enum PixelSelectionEngine {
    nonisolated static func cut(art: [RasterAtom], linework: [RasterAtom], points: [CGPoint], canvasSize: CGSize = PresentationDimensions.standard.size) -> PixelCut? {
        guard let image = DrawingRasterizer.render(art, size: canvasSize, canvasSize: canvasSize), let lines = DrawingRasterizer.render(linework, size: canvasSize, canvasSize: canvasSize), let first = points.first else { return nil }
        let path = CGMutablePath(); path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }; path.closeSubpath()
        let bounds = path.boundingBoxOfPath.integral.intersection(CGRect(origin: .zero, size: canvasSize))
        guard !bounds.isEmpty else { return nil }
        func masked(_ source: CGImage, cutout: Bool) -> CGImage? {
            guard let c = CGContext(data: nil, width: Int(canvasSize.width), height: Int(canvasSize.height), bitsPerComponent: 8, bytesPerRow: Int(canvasSize.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            c.translateBy(x: 0, y: canvasSize.height); c.scaleBy(x: 1, y: -1)
            if !cutout { c.addPath(path); c.clip() }
            c.saveGState(); c.translateBy(x: 0, y: canvasSize.height); c.scaleBy(x: 1, y: -1); c.draw(source, in: CGRect(origin: .zero, size: canvasSize)); c.restoreGState()
            if cutout { c.setBlendMode(.clear); c.addPath(path); c.fillPath() }
            return c.makeImage()
        }
        guard let selection = masked(image, cutout: false)?.cropping(to: bounds), let pixels = FillPixels(image: selection),
              stride(from: 3, to: pixels.rgba.count, by: 4).contains(where: { pixels.rgba[$0] != 0 }),
              let remaining = masked(image, cutout: true).flatMap(DrawingRasterizer.png),
              let selected = DrawingRasterizer.png(selection),
              let remainingLines = masked(lines, cutout: true).flatMap(DrawingRasterizer.png),
              let selectedLines = masked(lines, cutout: false)?.cropping(to: bounds).flatMap(DrawingRasterizer.png) else { return nil }
        return PixelCut(remaining: remaining, selected: selected, remainingLinework: remainingLines, selectedLinework: selectedLines, bounds: bounds)
    }
}

extension DeckStore {
    func selectRasterPixels(_ points: [CGPoint], objects: Set<UUID>) {
        let groups = DrawingRenderGroup.groups(editableElements).filter(\.drawing)
        guard !groups.isEmpty else { selectedIDs = objects; return }
        let requests = groups.map { (ids: Set($0.elements.map(\.id)), art: DrawingRasterizer.atoms($0.elements, store: self), lines: DrawingRasterizer.atoms($0.elements.filter { $0.kind != .fill }, store: self, linework: true)) }
        let revision = deckRevision, slideID = slide.id, layerID = activeLayer.id, canvasSize = canvasSize
        isSelectingPixels = true
        Task {
            let cuts = await Task.detached(priority: .userInitiated) { requests.compactMap { request -> (Set<UUID>, PixelCut)? in
                PixelSelectionEngine.cut(art: request.art, linework: request.lines, points: points, canvasSize: canvasSize).map { (request.ids, $0) }
            } }.value
            defer { isSelectingPixels = false }
            guard deckRevision == revision, slide.id == slideID, activeLayer.id == layerID else { return }
            guard !cuts.isEmpty else { selectedIDs = objects; return }
            do {
                var replacements: [(Set<UUID>, [SlideElement])] = []
                var selection = objects
                for (ids, cut) in cuts {
                    func save(_ data: Data) throws -> String {
                        let filename = UUID().uuidString + ".png"; try data.write(to: mediaFolder.appendingPathComponent(filename), options: .atomic); return filename
                    }
                    let rest = SlideElement(kind: .ink, x: 0, y: 0, width: canvasSize.width, height: canvasSize.height, asset: try save(cut.remaining), name: "Drawing", layerID: layerID, lineworkAsset: try save(cut.remainingLinework))
                    let part = SlideElement(kind: .ink, x: cut.bounds.minX, y: cut.bounds.minY, width: cut.bounds.width, height: cut.bounds.height, asset: try save(cut.selected), name: "Selected pixels", layerID: layerID, lineworkAsset: try save(cut.selectedLinework))
                    replacements.append((ids, [rest, part])); selection.insert(part.id)
                }
                checkpoint()
                var result: [SlideElement] = []
                var inserted = Set<Int>()
                for element in slide.elements {
                    if let i = replacements.firstIndex(where: { $0.0.contains(element.id) }) {
                        if inserted.insert(i).inserted { result += replacements[i].1 }
                    } else { result.append(element) }
                }
                deck.slides[active].elements = result; selectedIDs = selection; save()
                notify("Pixels selected")
            } catch { errorMessage = "Could not select drawing pixels: " + error.localizedDescription }
        }
    }
}

enum ElementOrder: String, CaseIterable {
    case front = "Bring to front", back = "Send to back", forward = "Bring forward", backward = "Send backward"
    var icon: String { switch self { case .front: "square.3.layers.3d.top.filled"; case .back: "square.3.layers.3d.bottom.filled"; case .forward: "arrow.up"; case .backward: "arrow.down" } }
}

extension DeckStore {
    func orderSelection(_ order: ElementOrder) {
        guard canEditActiveLayer, !selectedIDs.isEmpty else { return }
        var elements = slide.elements.filter { $0.layerID == activeLayer.id }
        let original = elements.map(\.id), selected = selectedIDs
        switch order {
        case .front: elements = elements.filter { !selected.contains($0.id) } + elements.filter { selected.contains($0.id) }
        case .back: elements = elements.filter { selected.contains($0.id) } + elements.filter { !selected.contains($0.id) }
        case .forward:
            if elements.count > 1 { for i in stride(from: elements.count - 2, through: 0, by: -1) where selected.contains(elements[i].id) && !selected.contains(elements[i + 1].id) { elements.swapAt(i, i + 1) } }
        case .backward:
            if elements.count > 1 { for i in 1..<elements.count where selected.contains(elements[i].id) && !selected.contains(elements[i - 1].id) { elements.swapAt(i, i - 1) } }
        }
        guard elements.map(\.id) != original else { return }
        checkpoint()
        var iterator = elements.makeIterator()
        deck.slides[active].elements = slide.elements.map { $0.layerID == activeLayer.id ? iterator.next()! : $0 }
        save()
    }
}
