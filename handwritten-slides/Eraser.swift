import SwiftUI
import PencilKit

nonisolated struct MarkPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    init(_ point: CGPoint) { x = point.x; y = point.y }
    var point: CGPoint { CGPoint(x: x, y: y) }
}
nonisolated struct EraserMark: Codable, Equatable, Sendable {
    var points: [MarkPoint]
    var brush: StudioBrush
    var width: Double
    var opacity: Double
    var seed: UInt32 = .random(in: 0...UInt32.max)
    @MainActor var bounds: CGRect { Geometry.bounds(points.map(\.point)).insetBy(dx: -width, dy: -width) }
}

struct EraserShape: View {
    var mark: EraserMark
    var body: some View {
        Canvas { context, size in
            let points = mark.points.map(\.point)
            guard let first = points.first else { return }
            context.opacity = mark.opacity
            if mark.brush == .round || mark.brush == .monoline || mark.brush == .ink {
                if points.count == 1 {
                    context.fill(Path(ellipseIn: CGRect(x: first.x - mark.width / 2, y: first.y - mark.width / 2, width: mark.width, height: mark.width)), with: .color(.white))
                } else { context.stroke(Geometry.path(points, close: false), with: .color(.white), style: StrokeStyle(lineWidth: mark.width, lineCap: .round, lineJoin: .round)) }
            } else if mark.brush == .flat {
                var path = Path()
                func stamp(_ point: CGPoint) {
                    let transform = CGAffineTransform(rotationAngle: -.pi / 6).concatenating(CGAffineTransform(translationX: point.x, y: point.y))
                    path.addPath(Path(CGRect(x: -mark.width / 2, y: -mark.width / 8, width: mark.width, height: mark.width / 4)), transform: transform)
                }
                stamp(first)
                for (a, b) in zip(points, points.dropFirst()) {
                    let count = max(1, Int(ceil(Geometry.distance(a, b) / max(1, mark.width * 0.1))))
                    for i in 1...count { let t = Double(i) / Double(count); stamp(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
                }
                context.fill(path, with: .color(.white))
            } else {
                let samples = points.enumerated().map { i, p in PKStrokePoint(location: p, timeOffset: Double(i) / 120, size: CGSize(width: mark.width, height: mark.width), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2) }
                let stroke = PKStroke(ink: PKInk(mark.brush.inkType, color: .white), path: PKStrokePath(controlPoints: samples, creationDate: .distantPast), randomSeed: mark.seed)
                let drawing = PKDrawing(strokes: [stroke])
                let bounds = drawing.bounds.insetBy(dx: -2, dy: -2)
                var preview = UIImage()
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent { preview = drawing.image(from: bounds, scale: 1) }
                context.draw(Image(uiImage: preview), in: bounds)
            }
        }
    }
}

extension DeckStore {
    func commitEraser(_ mark: EraserMark) {
        guard canEditActiveLayer, !mark.points.isEmpty else { return }
        let bounds = mark.bounds
        var normalized = mark
        normalized.points = mark.points.map { MarkPoint(CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
        checkpoint()
        deck.slides[active].elements.append(SlideElement(kind: .erase, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height, name: "\(mark.brush.title) eraser", layerID: activeLayer.id, eraser: normalized))
        save()
    }
}

struct StrokeStabilizer {
    private var position: CGPoint?
    private var pressure: Double = 0
    private var timestamp: Double = 0
    mutating func reset() { position = nil; pressure = 0; timestamp = 0 }
    mutating func sample(_ raw: CGPoint, pressure rawPressure: Double, time: Double, amount: Double) -> (CGPoint, Double)? {
        guard let previous = position else { position = raw; pressure = rawPressure; timestamp = time; return (raw, rawPressure) }
        guard time > timestamp else { return nil }
        let dt = max(1.0 / 240, time - timestamp)
        let speed = Geometry.distance(previous, raw) / dt
        let alpha = 1 - min(1, max(0, amount)) * 0.85 * exp(-speed / 900)
        let point = CGPoint(x: previous.x + (raw.x - previous.x) * alpha, y: previous.y + (raw.y - previous.y) * alpha)
        let pressureAlpha = 1 - exp(-dt / (0.004 + amount * 0.025))
        pressure += (rawPressure - pressure) * pressureAlpha
        position = point; timestamp = time
        return (point, pressure)
    }
}
