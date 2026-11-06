import SwiftUI
import Combine
import UniformTypeIdentifiers

struct SlideClipboard: Codable {
    static let type = "iyu.handwritten-slides.selection"
    var version = 1
    var elements: [SlideElement]
    var assets: [String: Data]
    var opacity: Double = 1
    var blendMode: LayerBlendMode = .normal
    var name = "Pasted"
}

enum ClipboardAction: String, CaseIterable, Identifiable {
    case cut = "Cut", copy = "Copy", copyAll = "Copy All", duplicate = "Duplicate", cutPaste = "Cut & Paste", paste = "Paste"
    var id: Self { self }
    var icon: String {
        switch self {
        case .cut: "scissors"
        case .copy: "doc.on.doc"
        case .copyAll: "square.3.layers.3d"
        case .duplicate: "plus.square.on.square"
        case .cutPaste: "scissors.badge.ellipsis"
        case .paste: "doc.on.clipboard"
        }
    }
}

extension DeckStore {
    var clipboardElements: [SlideElement] {
        slide.elements.filter { $0.layerID == activeLayer.id && (selectedIDs.isEmpty || selectedIDs.contains($0.id)) }
    }
    var canPaste: Bool { UIPasteboard.general.contains(pasteboardTypes: [SlideClipboard.type]) || UIPasteboard.general.hasImages }
    func canPerformClipboard(_ action: ClipboardAction, pasteboard: UIPasteboard = .general) -> Bool {
        switch action {
        case .paste: pasteboard.contains(pasteboardTypes: [SlideClipboard.type]) || pasteboard.hasImages
        case .copyAll: true
        case .cut, .cutPaste: canEditActiveLayer && !clipboardElements.isEmpty
        case .copy, .duplicate: !clipboardElements.isEmpty
        }
    }
    func showClipboard(at point: CGPoint? = nil) {
        canvasCommands.send(.finishStroke); canvasInteraction.send(); clipboardMenuPoint = point ?? CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
    }
    func makeClipboard(allVisible: Bool = false) throws -> SlideClipboard {
        if allVisible {
            guard let image = CanvasSnapshot.render(store: self)?.cgImage else { throw CocoaError(.fileReadCorruptFile) }
            let bounds = (selectionBounds ?? canvasBounds).integral.intersection(canvasBounds)
            guard !bounds.isEmpty, let cropped = image.cropping(to: bounds), let data = UIImage(cgImage: cropped).pngData() else { throw CocoaError(.fileReadCorruptFile) }
            let element = SlideElement(kind: .image, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height, asset: "canvas.png", name: "Canvas copy")
            return SlideClipboard(elements: [element], assets: ["canvas.png": data], name: "Canvas copy")
        }
        let elements = clipboardElements
        guard !elements.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var assets: [String: Data] = [:]
        for asset in Set(elements.flatMap { [$0.asset, $0.lineworkAsset].compactMap { $0 } }) {
            guard let url = assetURL(asset) else { throw CocoaError(.fileReadNoSuchFile) }
            assets[asset] = try Data(contentsOf: url)
        }
        return SlideClipboard(elements: elements, assets: assets, opacity: activeLayer.opacity, blendMode: activeLayer.blendMode, name: selectedIDs.isEmpty ? activeLayer.name : "Selection")
    }
    private func writeClipboard(_ payload: SlideClipboard, to pasteboard: UIPasteboard) throws {
        var item: [String: Any] = [SlideClipboard.type: try JSONEncoder().encode(payload)]
        // Provide a normal PNG for other apps, alongside editable objects for this app.
        var previewSlide = slide; previewSlide.elements = payload.elements
        let bounds = Geometry.bounds(payload.elements.flatMap(\.corners)).integral.intersection(canvasBounds)
        if !bounds.isEmpty {
            let layer = activeLayer
            let renderer = ImageRenderer(content: LayerElements(slide: previewSlide, layer: layer, store: self)
                .compositingGroup().opacity(payload.opacity).offset(x: -bounds.minX, y: -bounds.minY)
                .frame(width: bounds.width, height: bounds.height, alignment: .topLeading).clipped().environment(\.colorScheme, .light))
            renderer.scale = 1
            if let png = renderer.uiImage?.pngData() { item[UTType.png.identifier] = png }
        }
        pasteboard.setItems([item])
    }
    private func readClipboard(_ board: UIPasteboard) throws -> SlideClipboard {
        if let data = board.data(forPasteboardType: SlideClipboard.type) {
            return try JSONDecoder().decode(SlideClipboard.self, from: data)
        }
        guard let data = board.data(forPasteboardType: UTType.gif.identifier) ?? board.image?.pngData(), let image = ImportedImage(data: data) else { throw CocoaError(.fileReadCorruptFile) }
        let ratio = Double(image.size.width / image.size.height)
        let width: Double = min(800, canvasSize.width * 0.8, min(650, canvasSize.height * 0.8) * ratio), height = width / ratio
        let name = "clipboard." + image.fileExtension
        return SlideClipboard(elements: [SlideElement(kind: .image, x: (canvasSize.width - width) / 2, y: (canvasSize.height - height) / 2, width: width, height: height, asset: name, name: "Pasted image")], assets: [name: image.data])
    }
    func insertClipboard(_ payload: SlideClipboard, removing ids: Set<UUID> = []) throws {
        guard payload.version == 1, !payload.elements.isEmpty, payload.elements.count <= 20000,
              payload.opacity.isFinite, (0...1).contains(payload.opacity),
              payload.elements.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 && $0.width < 20000 && $0.height < 20000 && $0.rotation.isFinite && $0.fontSize.isFinite && $0.fontSize > 0 && $0.fontSize < 2000 }),
              ids.isEmpty || (canEditActiveLayer && ids.isSubset(of: Set(editableElements.map(\.id)))) else { throw CocoaError(.fileReadCorruptFile) }
        var replacements: [String: String] = [:]
        for asset in Set(payload.elements.flatMap { [$0.asset, $0.lineworkAsset].compactMap { $0 } }) {
            guard let data = payload.assets[asset] else { throw CocoaError(.fileReadNoSuchFile) }
            let ext = URL(fileURLWithPath: asset).pathExtension
            let filename = UUID().uuidString + "." + (ext.count <= 12 && ext.allSatisfy({ $0.isLetter || $0.isNumber }) ? ext : "bin")
            try data.write(to: mediaFolder.appendingPathComponent(filename), options: .atomic); replacements[asset] = filename
        }
        let layer = StudioLayer(name: payload.name, opacity: payload.opacity, blendMode: payload.blendMode)
        let elements = payload.elements.map { element in
            var copy = element; copy.id = UUID(); copy.layerID = layer.id
            if let asset = copy.asset { copy.asset = replacements[asset] }
            if let asset = copy.lineworkAsset { copy.lineworkAsset = replacements[asset] }
            return copy
        }
        let insertion = (layers.firstIndex { $0.id == activeLayer.id } ?? (layers.count - 1)) + 1
        checkpoint()
        deck.slides[active].elements.removeAll { ids.contains($0.id) }
        deck.slides[active].layers!.insert(layer, at: insertion)
        deck.slides[active].elements += elements
        activeLayerID = layer.id; selectedIDs = Set(elements.map(\.id)); tool = .transform; save()
    }
    func performClipboard(_ action: ClipboardAction, pasteboard: UIPasteboard = .general) {
        canvasCommands.send(.finishStroke); clipboardMenuPoint = nil
        guard canPerformClipboard(action, pasteboard: pasteboard) else { return }
        do {
            if action == .paste { try insertClipboard(readClipboard(pasteboard)); notify("Pasted to a new layer"); return }
            var payload = try makeClipboard(allVisible: action == .copyAll)
            if action == .copyAll {
                var item: [String: Any] = [SlideClipboard.type: try JSONEncoder().encode(payload)]
                item[UTType.png.identifier] = payload.assets["canvas.png"]
                pasteboard.setItems([item])
            } else { try writeClipboard(payload, to: pasteboard) }
            switch action {
            case .cut:
                let ids = Set(payload.elements.map(\.id)); checkpoint()
                deck.slides[active].elements.removeAll { ids.contains($0.id) }; selected = nil; save()
            case .duplicate:
                payload.name += " copy"; try insertClipboard(payload)
            case .cutPaste:
                let ids = Set(payload.elements.map(\.id)); payload.name = "From selection"; try insertClipboard(payload, removing: ids)
            default: break
            }
            notify(action.rawValue)
        } catch { errorMessage = "Could not \(action.rawValue.lowercased()): " + error.localizedDescription }
    }
}

struct ClipboardMenu: View {
    @ObservedObject var store: DeckStore
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Copy & Paste").font(.system(size: 15, weight: .semibold)); Spacer()
                Button { store.clipboardMenuPoint = nil } label: { Image(systemName: "xmark").frame(width: 24, height: 24) }.accessibilityLabel("Close Copy & Paste")
            }
            HStack(spacing: 4) {
                ForEach(ClipboardAction.allCases) { action in
                    Button { store.performClipboard(action) } label: {
                        VStack(spacing: 12) { Image(systemName: action.icon).font(.system(size: 24, weight: .regular)); Text(action.rawValue).font(.system(size: 11)) }
                            .frame(width: 75, height: 62).contentShape(Rectangle())
                    }.disabled(!store.canPerformClipboard(action)).accessibilityLabel(action.rawValue)
                }
            }
        }.frame(width: 470).padding(18).background(Color(white: 0.13), in: RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.12))).shadow(color: .black.opacity(0.4), radius: 20)
            .buttonStyle(.plain).foregroundStyle(Color(white: 0.83))
    }
}
