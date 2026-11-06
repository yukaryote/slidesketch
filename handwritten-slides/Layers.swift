import SwiftUI
import UniformTypeIdentifiers

nonisolated enum LayerBlendMode: String, CaseIterable, Codable, Identifiable {
    case normal = "Normal", multiply = "Multiply", darken = "Darken", colorBurn = "Color Burn"
    case screen = "Screen", lighten = "Lighten", colorDodge = "Color Dodge"
    case overlay = "Overlay", softLight = "Soft Light", hardLight = "Hard Light"
    case difference = "Difference", exclusion = "Exclusion"
    case hue = "Hue", saturation = "Saturation", color = "Color", luminosity = "Luminosity"
    var id: String { rawValue }
    var blend: BlendMode { switch self {
        case .normal: .normal; case .multiply: .multiply; case .darken: .darken; case .colorBurn: .colorBurn
        case .screen: .screen; case .lighten: .lighten; case .colorDodge: .colorDodge
        case .overlay: .overlay; case .softLight: .softLight; case .hardLight: .hardLight
        case .difference: .difference; case .exclusion: .exclusion
        case .hue: .hue; case .saturation: .saturation; case .color: .color; case .luminosity: .luminosity
    } }
}

nonisolated struct StudioLayer: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String = "Layer 1"
    var visible = true
    var locked = false
    var opacity: Double = 1
    var blendMode: LayerBlendMode = .normal
}

extension DeckStore {
    var layers: [StudioLayer] { slide.layers ?? [] }
    var activeLayer: StudioLayer { layers.first { $0.id == activeLayerID } ?? layers.last! }
    var canEditActiveLayer: Bool { activeLayer.visible && !activeLayer.locked }
    var editableElements: [SlideElement] { canEditActiveLayer ? slide.elements.filter { $0.layerID == activeLayer.id } : [] }
    static func withLayers(_ source: StudioDeck) -> StudioDeck {
        var result = source
        result.version = 2
        for i in result.slides.indices {
            if result.slides[i].layers?.isEmpty != false { result.slides[i].layers = [StudioLayer()] }
            let layers = result.slides[i].layers!
            if !layers.contains(where: { $0.id == result.slides[i].referenceLayerID }) { result.slides[i].referenceLayerID = nil }
            for j in result.slides[i].elements.indices {
                if !layers.contains(where: { $0.id == result.slides[i].elements[j].layerID }) {
                    result.slides[i].elements[j].layerID = layers[0].id
                }
            }
        }
        return result
    }
    func selectLayer(_ layer: StudioLayer) {
        activeLayerID = layer.id; selected = nil; lassoPoints = []
    }
    func addLayer() {
        checkpoint()
        let layer = StudioLayer(name: "Layer \(layers.count + 1)")
        let index = (layers.firstIndex { $0.id == activeLayer.id } ?? (layers.count - 1)) + 1
        deck.slides[active].layers!.insert(layer, at: index)
        selectLayer(layer); save()
    }
    func updateLayer(_ layer: StudioLayer) {
        guard let i = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        deck.slides[active].layers![i] = layer
        if !layer.visible || layer.locked { selected = nil }
    }
    func changeLayer(_ layer: StudioLayer, _ change: (inout StudioLayer) -> Void) {
        var updated = layer; change(&updated); checkpoint(); updateLayer(updated); save()
    }
    func moveDrawingLayer(_ layer: StudioLayer, by direction: Int) {
        guard let i = layers.firstIndex(where: { $0.id == layer.id }), layers.indices.contains(i + direction) else { return }
        checkpoint(); deck.slides[active].layers!.swapAt(i, i + direction); save()
    }
    func deleteDrawingLayer(_ layer: StudioLayer) {
        guard layers.count > 1 else { return }
        checkpoint(); deck.slides[active].layers!.removeAll { $0.id == layer.id }
        deck.slides[active].elements.removeAll { $0.layerID == layer.id }
        if slide.referenceLayerID == layer.id { deck.slides[active].referenceLayerID = nil }
        activeLayerID = layers.last?.id; selected = nil; save()
    }
    func duplicateDrawingLayer(_ layer: StudioLayer) {
        guard let index = layers.firstIndex(where: { $0.id == layer.id }) else { return }
        checkpoint()
        var copy = layer; copy.id = UUID(); copy.name += " copy"
        let elements = slide.elements.filter { $0.layerID == layer.id }.map { element in
            var copyElement = element; copyElement.id = UUID(); copyElement.layerID = copy.id; return copyElement
        }
        deck.slides[active].layers!.insert(copy, at: index + 1)
        deck.slides[active].elements += elements; selectLayer(copy); save()
    }
}

struct LayerElements: View {
    var slide: StudioSlide
    var layer: StudioLayer
    var store: DeckStore
    var presenting = false
    var animateImages = false
    var allowsVideoPreview = false
    var exportCanvasSize: CGSize?
    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(slide.elements.filter { $0.layerID == layer.id }) { element in
                SlideElementContent(element: element, store: store, presenting: presenting, animateImages: animateImages, allowsVideoPreview: allowsVideoPreview)
                    .rotationEffect(.degrees(element.rotation))
                    .position(x: element.x + element.width / 2, y: element.y + element.height / 2)
            }
        }.frame(width: (exportCanvasSize ?? store.canvasSize).width, height: (exportCanvasSize ?? store.canvasSize).height)
    }
}

struct EditableLayerElements: View {
    var slide: StudioSlide
    var layer: StudioLayer
    @ObservedObject var store: DeckStore
    var animateImages: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            // Split at selected pixels before a drag starts. The stationary bitmap
            // no longer subscribes to per-sample transform updates.
            ForEach(DrawingRenderGroup.groups(slide.elements.filter { $0.layerID == layer.id }, separating: store.selectedIDs)) { group in
                if group.drawing {
                    RasterDrawingView(elements: group.elements, store: store)
                } else if let element = group.elements.first {
                    EditableObjectSurface(element: element, store: store, animateImages: animateImages)
                }
            }
        }.frame(width: store.canvasSize.width, height: store.canvasSize.height)
    }
}

// Transparency is a preview aid only; these squares never become slide pixels.
private struct LayerTransparencyGrid: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 6
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.86)))
            for row in 0..<Int(ceil(size.height / tile)) {
                for column in 0..<Int(ceil(size.width / tile)) where (row + column).isMultiple(of: 2) {
                    context.fill(Path(CGRect(x: CGFloat(column) * tile, y: CGFloat(row) * tile, width: tile, height: tile)), with: .color(Color(white: 0.68)))
                }
            }
        }.accessibilityHidden(true)
    }
}

struct LayersPanel: View {
    @ObservedObject var store: DeckStore
    @State private var openSwipeLayer: UUID?
    @State private var draggedLayer: UUID?
    @State private var renameID: UUID?
    @State private var name = ""
    @State private var showRename = false
    @State private var showBackground = false
    private let blue = Color(hex: "3478F6")
    var body: some View {
        Group {
            if showBackground {
                BackgroundColorPanel(initialColor: store.slide.paper, onCancel: { showBackground = false }) { color, scope in
                    store.setBackground(color, scope: scope)
                    showBackground = false
                }
            } else { layerList }
        }
    }
    private var layerList: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Layers").font(.system(size: 25, weight: .bold)); Spacer(); Button { store.addLayer() } label: { Image(systemName: "plus").font(.title2) }.accessibilityLabel("Add layer") }
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(store.layers.reversed()) { layer in
                        VStack(spacing: 12) {
                            HStack(spacing: 10) {
                                Button { store.selectLayer(layer) } label: {
                                    HStack(spacing: 12) {
                                        ZStack {
                                            LayerTransparencyGrid()
                                            LayerElements(slide: store.slide, layer: layer, store: store).compositingGroup().opacity(layer.opacity).scaleEffect(0.04, anchor: .topLeading).frame(width: 64, height: 36, alignment: .topLeading)
                                        }.frame(width: 64, height: 42).clipped().clipShape(RoundedRectangle(cornerRadius: 4))
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(layer.name).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                                            if layer.locked { Label("Locked", systemImage: "lock.fill").font(.system(size: 10)) }
                                            if store.slide.referenceLayerID == layer.id { Text("Reference").font(.system(size: 10)) }
                                        }
                                        Spacer(minLength: 0)
                                    }
                                }.accessibilityLabel("Select \(layer.name)")
                                Menu {
                                    ForEach(LayerBlendMode.allCases) { mode in
                                        Button { store.changeLayer(layer) { $0.blendMode = mode } } label: { if mode == layer.blendMode { Label(mode.rawValue, systemImage: "checkmark") } else { Text(mode.rawValue) } }
                                    }
                                } label: { Text(layer.blendMode == .normal ? "N" : String(layer.blendMode.rawValue.prefix(1))).font(.system(size: 14)).frame(width: 28, height: 38) }.accessibilityLabel("Blend mode for \(layer.name): \(layer.blendMode.rawValue)")
                                Button { store.changeLayer(layer) { $0.visible.toggle() } } label: { Image(systemName: layer.visible ? "checkmark.square.fill" : "square").frame(width: 28, height: 38) }.accessibilityLabel(layer.visible ? "Hide \(layer.name)" : "Show \(layer.name)")
                            }
                            if store.activeLayer.id == layer.id {
                                HStack { Text("Opacity").font(.caption); Slider(value: Binding(get: { store.activeLayer.opacity }, set: { value in var current = store.activeLayer; current.opacity = value; store.updateLayer(current) }), in: 0...1, onEditingChanged: { if $0 { store.checkpoint() } else { store.save() } }).tint(.white).accessibilityLabel("Layer opacity"); Text("\(Int(layer.opacity * 100))%").font(.caption.monospacedDigit()).frame(width: 36) }
                                HStack {
                                    Text(layer.blendMode.rawValue).font(.caption)
                                    Spacer()
                                    Button { store.toggleReference(layer) } label: {
                                        Label("Reference", systemImage: store.slide.referenceLayerID == layer.id ? "checkmark.square.fill" : "square").font(.caption)
                                    }.accessibilityLabel(store.slide.referenceLayerID == layer.id ? "Remove reference layer" : "Set reference layer")
                                    Button { store.changeLayer(layer) { $0.locked.toggle() } } label: { Image(systemName: layer.locked ? "lock.fill" : "lock.open") }.accessibilityLabel(layer.locked ? "Unlock layer" : "Lock layer")
                                }
                            }
                        }.padding(12).background(store.activeLayer.id == layer.id ? blue : Color(white: 0.11), in: RoundedRectangle(cornerRadius: 7))
                            .modifier(LayerSwipeActions(store: store, layer: layer, openLayer: $openSwipeLayer))
                            .onDrag { openSwipeLayer = nil; draggedLayer = layer.id; return NSItemProvider(object: layer.id.uuidString as NSString) }
                            .onDrop(of: [.text], delegate: LayerReorderDrop(store: store, target: layer.id, dragged: $draggedLayer))
                            .contextMenu {
                                Button("Rename", systemImage: "pencil") { renameID = layer.id; name = layer.name; showRename = true }
                                Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicateDrawingLayer(layer) }
                                Button(store.slide.referenceLayerID == layer.id ? "Remove Reference" : "Reference", systemImage: "r.square") { store.toggleReference(layer) }
                                Button(layer.locked ? "Unlock" : "Lock", systemImage: "lock") { store.changeLayer(layer) { $0.locked.toggle() } }
                                Button("Move up", systemImage: "arrow.up") { store.moveDrawingLayer(layer, by: 1) }.disabled(store.layers.last?.id == layer.id)
                                Button("Move down", systemImage: "arrow.down") { store.moveDrawingLayer(layer, by: -1) }.disabled(store.layers.first?.id == layer.id)
                                Button("Delete", systemImage: "trash", role: .destructive) { store.deleteDrawingLayer(layer) }.disabled(store.layers.count == 1)
                            }
                    }
                }
            }.frame(maxHeight: 430)
            Button { showBackground = true } label: {
                HStack {
                    RoundedRectangle(cornerRadius: 4).fill(Color(hex: store.slide.paper)).frame(width: 64, height: 36)
                    Text("Background color").font(.system(size: 14))
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.accessibilityLabel("Background color").accessibilityValue(store.slide.paper)
        }.padding(22).frame(width: 370).background(Color(white: 0.145)).buttonStyle(.plain).preferredColorScheme(.dark)
            .alert("Layer name", isPresented: $showRename) {
                TextField("Name", text: $name)
                Button("Cancel", role: .cancel) {}
                Button("Save") { if let layer = store.layers.first(where: { $0.id == renameID }), !name.trimmingCharacters(in: .whitespaces).isEmpty { store.changeLayer(layer) { $0.name = name } } }
            }
    }
}

struct BackgroundColorPanel: View {
    @State private var color: String
    @State private var scope: BackgroundScope = .currentSlide
    var onCancel: () -> Void
    var onApply: (String, BackgroundScope) -> Void

    init(initialColor: String, onCancel: @escaping () -> Void, onApply: @escaping (String, BackgroundScope) -> Void) {
        _color = State(initialValue: initialColor)
        self.onCancel = onCancel
        self.onApply = onApply
    }
    var body: some View {
        VStack(spacing: 0) {
            StudioColorPicker(colorHex: $color, title: "Background color")
            Divider().padding(.horizontal, 22)
            VStack(alignment: .leading, spacing: 16) {
                Text("Apply to").font(.system(size: 12, weight: .semibold)).foregroundStyle(.gray)
                Picker("Apply background to", selection: $scope) {
                    ForEach(BackgroundScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
                }.pickerStyle(.segmented).accessibilityLabel("Apply background to")
                HStack {
                    Button("Cancel", action: onCancel).foregroundStyle(.secondary)
                    Spacer()
                    Button("Apply") { onApply(color, scope) }
                        .fontWeight(.semibold).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(Color(hex: "3478F6"), in: RoundedRectangle(cornerRadius: 8))
                        .accessibilityLabel(scope == .allSlides ? "Apply background to all slides" : "Apply background to current slide")
                }
            }.padding(22)
        }.frame(width: 330).background(Color(white: 0.145)).buttonStyle(.plain).preferredColorScheme(.dark)
    }
}
