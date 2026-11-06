import SwiftUI
import Combine

nonisolated struct PresentationDimensions: Codable, Hashable {
    var width: Int
    var height: Int
    static let standard = Self(width: 1600, height: 900)
    var isValid: Bool { (64...4000).contains(width) && (64...4000).contains(height) && width * height <= 12_000_000 }
    var size: CGSize { CGSize(width: width, height: height) }
    var label: String { "\(width) × \(height) px" }
}

extension DeckStore {
    var dimensions: PresentationDimensions { deck.dimensions.flatMap { $0.isValid ? $0 : nil } ?? .standard }
    var canvasSize: CGSize { dimensions.size }
    var canvasBounds: CGRect { CGRect(origin: .zero, size: canvasSize) }
    func resizePresentation(to dimensions: PresentationDimensions) {
        guard dimensions.isValid, dimensions != self.dimensions else { return }
        guard !isFilling, !isSelectingPixels else { notify("Wait for the canvas operation to finish"); return }
        canvasCommands.send(.finishStroke)
        let old = canvasSize, next = dimensions.size
        let scale = min(next.width / old.width, next.height / old.height)
        let dx = (next.width - old.width * scale) / 2, dy = (next.height - old.height * scale) / 2
        checkpoint()
        for s in deck.slides.indices {
            for e in deck.slides[s].elements.indices {
                var element = deck.slides[s].elements[e]
                element.x = element.x * scale + dx; element.y = element.y * scale + dy
                element.width *= scale; element.height *= scale
                if element.kind == .text { element.fontSize *= scale }
                deck.slides[s].elements[e] = element
            }
        }
        deck.dimensions = dimensions
        selected = nil; liveEraser = nil; transformPreview.elements = [:]; lassoPoints = []
        save(); notify("Presentation size: " + dimensions.label)
    }
}

struct PresentationDimensionsPanel: View {
    @ObservedObject var store: DeckStore
    @Environment(\.dismiss) private var dismiss
    @State private var width = ""
    @State private var height = ""
    private var choice: PresentationDimensions? {
        guard let w = Int(width), let h = Int(height) else { return nil }
        let result = PresentationDimensions(width: w, height: h)
        return result.isValid ? result : nil
    }
    private let presets: [(String, PresentationDimensions)] = [
        ("Widescreen", .standard),
        ("Full HD", .init(width: 1920, height: 1080)),
        ("Standard 4:3", .init(width: 1600, height: 1200)),
        ("Portrait", .init(width: 1080, height: 1920)),
        ("Square", .init(width: 1080, height: 1080)),
        ("4K", .init(width: 3840, height: 2160))
    ]
    var body: some View {
        NavigationStack {
            Form {
                Section("Presets") {
                    ForEach(presets, id: \.0) { name, size in
                        Button { width = String(size.width); height = String(size.height) } label: {
                            HStack { Text(name); Spacer(); Text(size.label).foregroundStyle(.secondary); if choice == size { Image(systemName: "checkmark") } }
                        }
                    }
                }
                Section("Custom size in pixels") {
                    HStack { Text("Width"); TextField("Width", text: $width).multilineTextAlignment(.trailing).keyboardType(.numberPad).accessibilityLabel("Presentation width") }
                    HStack { Text("Height"); TextField("Height", text: $height).multilineTextAlignment(.trailing).keyboardType(.numberPad).accessibilityLabel("Presentation height") }
                    Button("Swap width and height") { let previous = width; width = height; height = previous }
                }
                Section {
                    Text("Applies to every slide. Existing content is scaled proportionally and centered. You can undo this change.")
                    Text("Each side can be 64–4000 pixels, up to 12 million pixels total. Larger canvases use more memory.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Presentation size").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Apply") { if let choice { store.resizePresentation(to: choice); dismiss() } }.disabled(choice == nil || choice == store.dimensions) }
            }
            .onAppear { width = String(store.dimensions.width); height = String(store.dimensions.height) }
        }.preferredColorScheme(.dark)
    }
}
