import SwiftUI

struct PressureCurve: Codable, Equatable {
    var x1: Double = 0.25
    var y1: Double = 0.25
    var x2: Double = 0.75
    var y2: Double = 0.75
    static let linear = PressureCurve()
    static let soft = PressureCurve(x1: 0.15, y1: 0.55, x2: 0.5, y2: 0.95)
    static let firm = PressureCurve(x1: 0.45, y1: 0.05, x2: 0.85, y2: 0.45)
    var isLinear: Bool { abs(x1 - y1) < 0.001 && abs(x2 - y2) < 0.001 }
    func value(at input: Double) -> Double {
        let input = min(1, max(0, input))
        if input == 0 || input == 1 { return input }
        func cubic(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
        var lo = 0.0, hi = 1.0
        for _ in 0..<24 { let mid = (lo + hi) / 2; if cubic(mid, x1, x2) < input { lo = mid } else { hi = mid } }
        return cubic((lo + hi) / 2, y1, y2)
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: "PencilPressureCurve"), let value = try? JSONDecoder().decode(Self.self, from: data), [value.x1, value.y1, value.x2, value.y2].allSatisfy({ $0.isFinite && (0...1).contains($0) }), value.x1 <= value.x2, value.y1 <= value.y2 else { return .linear }
        return value
    }
    func save() { if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: "PencilPressureCurve") } }
}

struct PencilResponse {
    let size: CGSize
    let opacity: Double
    let force: Double
    init(pressure: Double, altitude: Double, brush: StudioBrush, width: Double, curve: PressureCurve) {
        force = curve.value(at: pressure)
        let tilt = brush.supportsTilt ? max(0, 1 - sin(altitude)) : 0
        let base = width * (0.15 + 0.85 * force)
        size = CGSize(width: base * (1 + tilt * 4), height: base * (1 + tilt) * (brush == .flat ? 0.25 : 1))
        opacity = (brush.supportsTilt || brush == .watercolor) ? 0.25 + 0.75 * force : 1
    }
}

struct PressureCurvePanel: View {
    @ObservedObject var store: DeckStore
    @Environment(\.dismiss) private var dismiss
    private let blue = Color(hex: "3C82F6")
    var body: some View {
        NavigationStack {
            ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Pressure response").font(.title2.bold())
                Text("Drag the two points to change how your Apple Pencil responds. A higher curve gives you more ink with a lighter touch.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    Button("Light touch") { store.pressureCurve = .soft }
                    Button("Linear") { store.pressureCurve = .linear }
                    Button("Firm touch") { store.pressureCurve = .firm }
                    Spacer()
                    Button("Reset") { store.pressureCurve = .linear }
                }.buttonStyle(.bordered)
                GeometryReader { geometry in
                    let side = min(geometry.size.width, geometry.size.height)
                    ZStack {
                        RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.13))
                        Canvas { context, _ in
                            var grid = Path()
                            for i in 0...4 {
                                let p = side * Double(i) / 4
                                grid.move(to: CGPoint(x: p, y: 0)); grid.addLine(to: CGPoint(x: p, y: side))
                                grid.move(to: CGPoint(x: 0, y: p)); grid.addLine(to: CGPoint(x: side, y: p))
                            }
                            context.stroke(grid, with: .color(.white.opacity(0.1)), lineWidth: 1)
                            var diagonal = Path(); diagonal.move(to: CGPoint(x: 0, y: side)); diagonal.addLine(to: CGPoint(x: side, y: 0))
                            context.stroke(diagonal, with: .color(.white.opacity(0.2)), style: StrokeStyle(lineWidth: 1, dash: [5]))
                            var curve = Path(); curve.move(to: CGPoint(x: 0, y: side))
                            curve.addCurve(to: CGPoint(x: side, y: 0), control1: CGPoint(x: store.pressureCurve.x1 * side, y: (1 - store.pressureCurve.y1) * side), control2: CGPoint(x: store.pressureCurve.x2 * side, y: (1 - store.pressureCurve.y2) * side))
                            context.stroke(curve, with: .color(blue), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        }
                        handle(1, side: side)
                        handle(2, side: side)
                    }.frame(width: side, height: side).coordinateSpace(name: "pressure-graph")
                        .frame(maxWidth: .infinity)
                }.frame(height: 310)
                HStack { Text("Light pressure"); Spacer(); Text("Heavy pressure") }.font(.caption).foregroundStyle(.secondary)
                Canvas { context, size in
                    for i in 0..<160 {
                        let t = Double(i) / 159, p = sin(t * .pi)
                        let response = store.pressureCurve.value(at: p)
                        let radius = 1.5 + response * 15
                        let rect = CGRect(x: t * (size.width - 32) + 16 - radius, y: size.height / 2 - radius, width: radius * 2, height: radius * 2)
                        context.fill(Path(ellipseIn: rect), with: .color(.white.opacity(0.25 + response * 0.75)))
                    }
                }.frame(height: 55).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                Text("Stroke preview · width & opacity").font(.caption).foregroundStyle(.secondary)
                HStack { Text("Pencil stabilization"); Slider(value: $store.stabilization, in: 0...1).accessibilityLabel("Pencil stabilization"); Text("\(Int(store.stabilization * 100))%").monospacedDigit().frame(width: 42) }
                Text("Smooths small movements while retaining fast, expressive strokes.").font(.caption).foregroundStyle(.secondary)
                Text("With Soft Graphite or Fine Pencil, hold Apple Pencil upright for a fine point and tilt it toward the screen for broad, softly graded shading. The paper grain keeps its size. Mouse and finger input use speed-based dynamics; the pressure curve and tilt apply to Apple Pencil.").font(.footnote).foregroundStyle(.secondary)
            }.padding(30).frame(maxWidth: 640).frame(maxWidth: .infinity)
            }
                .background(Color(white: 0.09))
                .navigationTitle("Apple Pencil").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }
    private func handle(_ index: Int, side: Double) -> some View {
        let x = index == 1 ? store.pressureCurve.x1 : store.pressureCurve.x2
        let y = index == 1 ? store.pressureCurve.y1 : store.pressureCurve.y2
        return Circle().fill(.white).overlay(Circle().stroke(blue, lineWidth: 3)).frame(width: 22, height: 22)
            .frame(width: 44, height: 44).contentShape(Circle())
            .position(x: x * side, y: (1 - y) * side)
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("pressure-graph")).onChanged { value in
                var curve = store.pressureCurve
                let newX = min(1, max(0, value.location.x / side)), newY = min(1, max(0, 1 - value.location.y / side))
                if index == 1 { curve.x1 = min(curve.x2, newX); curve.y1 = min(curve.y2, newY) }
                else { curve.x2 = max(curve.x1, newX); curve.y2 = max(curve.y1, newY) }
                store.pressureCurve = curve
            })
            .accessibilityLabel(index == 1 ? "Light pressure control point" : "Heavy pressure control point")
            .accessibilityValue("\(Int(x * 100)) percent pressure, \(Int(y * 100)) percent response")
            .accessibilityAdjustableAction { direction in
                var curve = store.pressureCurve
                if index == 1 { curve.y1 = min(curve.y2, max(0, curve.y1 + (direction == .increment ? 0.05 : -0.05))) }
                else { curve.y2 = min(1, max(curve.y1, curve.y2 + (direction == .increment ? 0.05 : -0.05))) }
                store.pressureCurve = curve
            }
    }
}
