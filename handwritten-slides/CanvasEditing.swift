import SwiftUI
import PencilKit
import Combine

@MainActor
final class CanvasTransformPreview: ObservableObject {
    @Published var elements: [UUID: SlideElement] = [:]
}


@MainActor
extension SlideElement {
    var center: CGPoint { CGPoint(x: x + width / 2, y: y + height / 2) }
    var corners: [CGPoint] {
        let w: CGFloat = width / 2
        let h: CGFloat = height / 2
        let rotation = CGAffineTransform(rotationAngle: rotation * .pi / 180)
        let translation = CGAffineTransform(translationX: center.x, y: center.y)
        let points: [CGPoint] = [CGPoint(x: -w, y: -h), CGPoint(x: w, y: -h), CGPoint(x: w, y: h), CGPoint(x: -w, y: h)]
        return points.map { $0.applying(rotation).applying(translation) }
    }
    func inkPoints() -> [CGPoint] {
        guard kind == .ink, let data = drawing, let drawing = try? PKDrawing(data: data) else { return [] }
        let bounds = drawing.bounds.insetBy(dx: -4, dy: -4)
        let sx = width / bounds.width, sy = height / bounds.height
        let angle = CGAffineTransform(rotationAngle: rotation * .pi / 180)
        let offset = CGAffineTransform(translationX: center.x, y: center.y)
        var points: [CGPoint] = []
        for stroke in drawing.strokes {
            for point in stroke.path.interpolatedPoints(by: .distance(5)) {
                let location = point.location.applying(stroke.transform)
                var x: Double = (location.x - bounds.minX) * sx
                var y: Double = (location.y - bounds.minY) * sy
                if flipX == true { x = width - x }
                if flipY == true { y = height - y }
                points.append(CGPoint(x: x - width / 2, y: y - height / 2).applying(angle).applying(offset))
            }
        }
        return points
    }
    var extent: CGRect { Geometry.bounds(corners) }
    func localPoint(_ point: CGPoint) -> CGPoint {
        let dx = point.x - center.x, dy = point.y - center.y, a = -rotation * .pi / 180
        return CGPoint(x: dx * cos(a) - dy * sin(a) + width / 2, y: dx * sin(a) + dy * cos(a) + height / 2)
    }
    func contains(_ point: CGPoint, tolerance: Double = 0) -> Bool {
        CGRect(x: -tolerance, y: -tolerance, width: width + tolerance * 2, height: height + tolerance * 2).contains(localPoint(point))
    }
}

enum Geometry {
    static func bounds(_ points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }
    static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
    static func path(_ points: [CGPoint], close: Bool = true) -> Path {
        var path = Path(); guard let first = points.first else { return path }
        path.move(to: first); points.dropFirst().forEach { path.addLine(to: $0) }
        if close { path.closeSubpath() }; return path
    }
    static func selectionPoints(_ input: [CGPoint], shape: SelectionShape) -> [CGPoint] {
        guard let first = input.first, let last = input.last else { return [] }
        if shape == .freehand { return input }
        let r = bounds([first, last])
        if shape == .rectangle { return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] }
        return (0..<64).map { i in let a = Double(i) * .pi / 32; return CGPoint(x: r.midX + cos(a) * r.width / 2, y: r.midY + sin(a) * r.height / 2) }
    }
    static func handles(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)]
    }
}

extension DeckStore {
    var selectionBounds: CGRect? {
        let corners = slide.elements.filter { selectedIDs.contains($0.id) }.map { transformPreview.elements[$0.id] ?? $0 }.flatMap(\.corners)
        return corners.isEmpty ? nil : Geometry.bounds(corners)
    }
    func selectLasso(_ input: [CGPoint]) {
        let points = Geometry.selectionPoints(input, shape: selectionShape)
        guard points.count >= 3 else { selected = nil; return }
        let polygon = Geometry.path(points)
        var matches = Set<UUID>()
        for element in editableElements where !element.isDrawingContent {
            if polygon.contains(element.center) || element.corners.contains(where: { polygon.contains($0) }) || points.contains(where: { element.contains($0) }) { matches.insert(element.id) }
        }
        selectRasterPixels(points, objects: matches)
    }

    func invertSelection() { selectedIDs = Set(editableElements.map(\.id)).subtracting(selectedIDs) }
    func rotateSelection() {
        guard let rect = selectionBounds else { return }; checkpoint()
        for var e in slide.elements where selectedIDs.contains(e.id) {
            let dx = e.center.x - rect.midX, dy = e.center.y - rect.midY
            e.x = rect.midX - dy - e.width / 2; e.y = rect.midY + dx - e.height / 2
            e.rotation += 90; update(e)
        }; save()
    }
    func flipSelection(horizontal: Bool) {
        guard let rect = selectionBounds else { return }; checkpoint()
        for var e in slide.elements where selectedIDs.contains(e.id) {
            if horizontal { e.x = 2 * rect.midX - e.x - e.width; e.flipX = !(e.flipX ?? false) }
            else { e.y = 2 * rect.midY - e.y - e.height; e.flipY = !(e.flipY ?? false) }
            e.rotation = -e.rotation; update(e)
        }; save()
    }
}

@MainActor
final class CanvasEditingSession {
    enum Operation { case move, resize(Int), rotate, erase }
    private var operation: Operation?
    private var originals: [SlideElement] = []
    private var originalBounds = CGRect.zero
    private var start = CGPoint.zero
    private var checkpointed = false
    private var slideID: UUID?
    private var selectedTapID: UUID?
    private var maxTravel = 0.0

    func begin(at point: CGPoint, store: DeckStore, scale: Double) {
        store.transformPreview.elements = [:]
        operation = nil; originals = []; start = point; checkpointed = false; slideID = store.slide.id
        maxTravel = 0
        selectedTapID = nil
        if store.selectedIDs.count == 1, let element = store.selectedElement,
           element.kind == .text || element.kind == .video, element.contains(point) { selectedTapID = element.id }
        if store.tool == .select { store.lassoPoints = [point]; return }
        if store.tool == .erase {
            guard store.canEditActiveLayer else { return }
            operation = .erase
            store.liveEraser = EraserMark(points: [MarkPoint(point)], brush: store.eraserBrush, width: store.eraserSize, opacity: store.eraserOpacity)
            return
        }
        guard store.tool == .transform else { return }
        if let bounds = store.selectionBounds {
            let rotationPoint = CGPoint(x: bounds.midX, y: bounds.minY - 35 / scale)
            if Geometry.distance(point, rotationPoint) < 20 / scale { operation = .rotate }
            else if let index = Geometry.handles(bounds).enumerated().filter({ store.selectedText == nil || $0.offset == 3 || $0.offset == 7 }).min(by: { Geometry.distance($0.element, point) < Geometry.distance($1.element, point) }), Geometry.distance(index.element, point) < 19 / scale { operation = .resize(index.offset) }
            else if bounds.contains(point) { operation = .move }
        }
        if operation == nil {
            store.selected = store.editableElements.reversed().first { $0.contains(point, tolerance: 6 / scale) }?.id
            if store.selected != nil { operation = .move }
        }
        if case .move = operation {} else { selectedTapID = nil }
        originals = store.slide.elements.filter { store.selectedIDs.contains($0.id) }
        originalBounds = store.selectionBounds ?? .zero
    }
    func change(to point: CGPoint, store: DeckStore, scale: Double) {
        guard slideID == store.slide.id else { return }
        maxTravel = max(maxTravel, Geometry.distance(start, point))
        if store.tool == .select { store.lassoPoints.append(point); return }
        guard let operation else { return }
        if case .erase = operation { store.liveEraser?.points.append(MarkPoint(point)); return }
        guard maxTravel > 4 / scale || checkpointed else { return }
        checkpointed = true
        let dx = point.x - start.x, dy = point.y - start.y
        var preview: [UUID: SlideElement] = [:]
        for var e in originals {
            switch operation {
            case .move: e.x += dx; e.y += dy
            case .rotate:
                let angle = atan2(point.y - originalBounds.midY, point.x - originalBounds.midX) - atan2(start.y - originalBounds.midY, start.x - originalBounds.midX)
                let x = e.center.x - originalBounds.midX, y = e.center.y - originalBounds.midY
                e.x = originalBounds.midX + x * cos(angle) - y * sin(angle) - e.width / 2
                e.y = originalBounds.midY + x * sin(angle) + y * cos(angle) - e.height / 2
                e.rotation += angle * 180 / .pi
            case .resize(let index):
                let handle = Geometry.handles(originalBounds)[index]
                let anchor = Geometry.handles(originalBounds)[(index + 4) % 8]
                let horizontal = abs(handle.x - anchor.x) > 0.5, vertical = abs(handle.y - anchor.y) > 0.5
                var sx = horizontal ? max(0.05, min(20, (handle.x + dx - anchor.x) / (handle.x - anchor.x))) : 1
                var sy = vertical ? max(0.05, min(20, (handle.y + dy - anchor.y) / (handle.y - anchor.y))) : 1
                if originals.count == 1, e.kind == .text {
                    e.width = max(40, min(16000, e.width * sx))
                    e.x = anchor.x + (e.x - anchor.x) * (e.width / originals[0].width)
                    e.height = e.fittedTextHeight
                    preview[e.id] = e
                    continue
                }
                if store.uniformTransform {
                    let factor = horizontal && vertical ? (abs(sx - 1) > abs(sy - 1) ? sx : sy) : horizontal ? sx : sy
                    sx = factor; sy = factor
                }
                let cx = anchor.x + (e.center.x - anchor.x) * sx, cy = anchor.y + (e.center.y - anchor.y) * sy
                e.width *= sx; e.height *= sy; e.x = cx - e.width / 2; e.y = cy - e.height / 2
                if e.kind == .text { e.fontSize *= min(sx, sy) }
            case .erase: break
            }
            preview[e.id] = e
        }
        store.transformPreview.elements = preview
    }
    func end(at point: CGPoint, store: DeckStore, scale: Double, cancelled: Bool = false) {
        guard slideID == store.slide.id else { store.transformPreview.elements = [:]; return }
        defer { store.transformPreview.elements = [:] }
        maxTravel = max(maxTravel, Geometry.distance(start, point))
        if store.tool == .erase {
            if !cancelled, var mark = store.liveEraser { mark.points.append(MarkPoint(point)); store.commitEraser(mark) }
            store.liveEraser = nil
        } else if store.tool == .select {
            if !cancelled {
                if maxTravel <= 4 / scale {
                    if let selectedTapID { store.tappedSelectedElement(selectedTapID) }
                    else { store.selected = store.editableElements.reversed().first { $0.contains(point, tolerance: 6 / scale) }?.id }
                } else { store.lassoPoints.append(point); store.selectLasso(store.lassoPoints) }
            }
            store.lassoPoints = []
        } else if cancelled {
            store.transformPreview.elements = [:]
        } else {
            change(to: point, store: store, scale: scale)
            if checkpointed {
                store.checkpoint()
                let updates = store.transformPreview.elements
                store.deck.slides[store.active].elements = store.slide.elements.map { updates[$0.id] ?? $0 }
                store.save()
            }
            else if maxTravel <= 4 / scale, let selectedTapID { store.tappedSelectedElement(selectedTapID) }
        }
        operation = nil; originals = []; checkpointed = false; selectedTapID = nil
    }

}

@MainActor
enum CanvasSnapshot {
    static func render(store: DeckStore) -> UIImage? {
        let renderer = ImageRenderer(content: StaticSlide(slide: store.slide, store: store).environment(\.colorScheme, .light))
        renderer.scale = 1
        return renderer.uiImage
    }
    static func color(in image: UIImage, at point: CGPoint, canvasSize: CGSize = PresentationDimensions.standard.size) -> String? {
        guard let cg = image.cgImage, point.x >= 0, point.y >= 0, point.x < canvasSize.width, point.y < canvasSize.height else { return nil }
        let x = floor(point.x / canvasSize.width * Double(cg.width)), y = floor(point.y / canvasSize.height * Double(cg.height))
        guard let pixel = cg.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var rgba: [UInt8] = [0, 0, 0, 0]
        rgba.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return String(format: "%02X%02X%02X", rgba[0], rgba[1], rgba[2])
    }
}
