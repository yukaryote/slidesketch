import SwiftUI
import PencilKit

struct BrushSizeBookmarks: Codable {
    static let limit = 4
    private static let storageKey = "BrushSizeBookmarks.v1"
    private var entries: [String: [Double]] = [:]

    private func key(_ brush: StudioBrush, erasing: Bool, customID: UUID?) -> String { "\(erasing ? "erase" : "draw").\(customID?.uuidString ?? brush.rawValue)" }
    func sizes(for brush: StudioBrush, erasing: Bool, customID: UUID? = nil) -> [Double] { entries[key(brush, erasing: erasing, customID: customID)] ?? [] }
    func savedSize(near size: Double, brush: StudioBrush, erasing: Bool, customID: UUID? = nil) -> Double? {
        sizes(for: brush, erasing: erasing, customID: customID).first { abs($0 - size) < 0.051 }
    }
    mutating func toggle(_ size: Double, brush: StudioBrush, erasing: Bool, customID: UUID? = nil) {
        guard size.isFinite, (1...100).contains(size) else { return }
        let key = key(brush, erasing: erasing, customID: customID)
        var sizes = entries[key] ?? []
        if let index = sizes.firstIndex(where: { abs($0 - size) < 0.051 }) { sizes.remove(at: index) }
        else if sizes.count < Self.limit { sizes.append((size * 10).rounded() / 10) }
        entries[key] = sizes.sorted()
    }
    static func load() -> Self {
        guard let data = UserDefaults.standard.data(forKey: storageKey), let decoded = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        var clean = Self()
        for (key, sizes) in decoded.entries {
            let valid = sizes.filter { $0.isFinite && (1...100).contains($0) }.map { ($0 * 10).rounded() / 10 }
            clean.entries[key] = Array(Set(valid).sorted().prefix(limit))
        }
        return clean
    }
    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }
    static func label(_ size: Double) -> String {
        let value = (size * 10).rounded() / 10
        return value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

struct BrushSizeControl: View {
    @ObservedObject var store: DeckStore
    @State private var showPreview = false
    private var erasing: Bool { store.tool == .erase }
    private var brush: StudioBrush { erasing ? store.eraserBrush : store.brush }
    private var size: Double { erasing ? store.eraserSize : store.brushSize }
    private var bookmarks: [Double] { store.sizeBookmarks.sizes(for: brush, erasing: erasing, customID: store.activeImportedBrush?.id) }
    private var savedSize: Double? { store.sizeBookmarks.savedSize(near: size, brush: brush, erasing: erasing, customID: store.activeImportedBrush?.id) }
    private let blue = Color(hex: "3478F6")

    var body: some View {
        StudioVerticalSlider(value: Binding(get: { size }, set: { setSize($0) }), range: 1...100, label: erasing ? "Eraser size" : "Brush size", bookmarks: bookmarks, onInteraction: { showPreview = true })
            .accessibilityAction(named: Text("Show size bookmarks")) { showPreview = true }
            .overlay(alignment: .topLeading) {
                if showPreview { preview.offset(x: 45, y: -20) }
            }
            .onReceive(store.canvasInteraction) { showPreview = false }
            .onChange(of: store.tool) { showPreview = false }
            .onChange(of: brush) { showPreview = false }
            .onChange(of: store.slide.id) { showPreview = false }
            .zIndex(1)
    }
    private var preview: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Size \(BrushSizeBookmarks.label(size))").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                Spacer()
                Button {
                    let existing = savedSize
                    store.sizeBookmarks.toggle(size, brush: brush, erasing: erasing, customID: store.activeImportedBrush?.id)
                    if existing == nil, let saved = savedSize { setSize(saved) }
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    Image(systemName: savedSize == nil ? "plus" : "minus").font(.system(size: 18)).frame(width: 36, height: 36)
                }
                .disabled(savedSize == nil && bookmarks.count == BrushSizeBookmarks.limit)
                .accessibilityLabel(savedSize == nil ? "Save size bookmark" : "Remove size bookmark")
            }
            BrushSizePreview(brush: brush, size: size).frame(height: 80).accessibilityHidden(true)
            Text((store.activeImportedBrush?.name ?? brush.title) + (erasing ? " · Eraser" : "")).font(.system(size: 12)).foregroundStyle(.secondary)
            if bookmarks.isEmpty {
                Text("Tap + to save this size").font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 5) {
                    ForEach(bookmarks, id: \.self) { bookmark in
                        Button { setSize(bookmark); UISelectionFeedbackGenerator().selectionChanged() } label: {
                            Text(BrushSizeBookmarks.label(bookmark)).font(.system(size: 12, weight: .medium)).monospacedDigit()
                                .frame(maxWidth: .infinity).frame(height: 30)
                                .background(savedSize == bookmark ? blue : .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                        }.accessibilityLabel("Use size bookmark \(BrushSizeBookmarks.label(bookmark))")
                    }
                }
                if bookmarks.count == BrushSizeBookmarks.limit && savedSize == nil {
                    Text("4 saved · select a mark to remove it").font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }
        }.padding(14).frame(width: 210).background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.07)))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
            .foregroundStyle(.white).buttonStyle(.plain).preferredColorScheme(.dark)
    }
    private func setSize(_ value: Double) {
        if erasing { store.eraserSize = value } else { store.brushSize = value }
    }
}

private struct BrushSizePreview: View {
    var brush: StudioBrush
    var size: Double
    var body: some View {
        Image(uiImage: preview).resizable().scaledToFit()
    }
    private var preview: UIImage {
        let points = (0...12).map { i in
            PKStrokePoint(location: CGPoint(x: 60 + i * 5, y: 60), timeOffset: Double(i) / 120, size: CGSize(width: size, height: brush == .flat ? size * 0.25 : size), opacity: 1, force: 1, azimuth: brush == .flat ? -.pi / 6 : 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(brush.inkType, color: .white), path: PKStrokePath(controlPoints: points, creationDate: .distantPast), randomSeed: 42)
        var result = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent { result = PKDrawing(strokes: [stroke]).image(from: CGRect(x: 0, y: 0, width: 180, height: 120), scale: 1.5) }
        return result
    }
}
