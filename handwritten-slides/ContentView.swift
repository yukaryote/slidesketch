import SwiftUI
import Combine
import PhotosUI
import AVKit
import UniformTypeIdentifiers

private enum ImportPurpose { case image, video, deck }

struct ContentView: View {
    @StateObject private var store: DeckStore
    @MainActor init(store: DeckStore? = nil) { _store = StateObject(wrappedValue: store ?? DeckStore()) }
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSlides = true
    @State private var showActions = false
    @State private var pendingAction: (() -> Void)?
    @StateObject private var viewport = CanvasViewportState()
    @State private var viewportFrame = CGRect.zero
    @State private var draggedSlideID: UUID?
    @State private var dropSlideID: UUID?
    private var canvasFrame: CGRect { viewport.canvasRect.offsetBy(dx: viewportFrame.minX, dy: viewportFrame.minY) }
    @State private var colorDropPosition: CGPoint?
    @State private var colorDropThresholdActive = false
    @State private var showGallery = false
    @State private var showPressure = false
    @State private var showDimensions = false
    @State private var showBrushes = false
    @State private var showColors = false
    @State private var showErasers = false
    @State private var showLayers = false
    @State private var showProperties = false
    @State private var textEditor: TextEditorRequest?
    @State private var showRename = false
    @State private var renamedTitle = ""
    @State private var showHelp = false
    @State private var showPresentation = false
    @State private var showImporter = false
    @State private var importPurpose: ImportPurpose = .image
    @State private var showPhotoPicker = false
    @State private var photoItem: PhotosPickerItem?
    @State private var exportDocument: DeckDocument?
    @State private var exportContentType: UTType = .json
    @State private var showExporter = false
    @State private var showKeynoteInfo = false
    @State private var videoPreview: VideoPreviewItem?
    private let chrome = Color(white: 0.105)
    private let accent = Color(hex: "3C82F6")

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            GeometryReader { geometry in
                ZStack {
                    workspaceGrid
                    CanvasViewport(state: viewport, content: editorCanvas(scale: viewport.scale), canvasSize: store.canvasSize).id(store.dimensions)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("editor-space")) } action: { viewportFrame = $0 }
                    HStack(spacing: 12) {
                        Button { viewport.command = .zoomOut } label: { Image(systemName: "minus.magnifyingglass") }.accessibilityLabel("Zoom out")
                        Button { viewport.command = .fit } label: { Text("\(Int(viewport.scale * 100))%").monospacedDigit() }.accessibilityLabel("Fit canvas")
                        Button { viewport.command = .zoomIn } label: { Image(systemName: "plus.magnifyingglass") }.accessibilityLabel("Zoom in")
                    }.font(.system(size: 12)).buttonStyle(.plain).padding(10)
                        .background(chrome.opacity(0.9), in: Capsule()).padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    drawingControls.padding(.leading, 9).frame(maxWidth: .infinity, alignment: .leading)
                    if store.tool == .select || store.tool == .transform {
                        VStack(spacing: 6) {
                            if store.selectedIDs.count == 1, let element = store.selectedElement {
                                if element.kind == .video { VideoOptionsBar(store: store, element: element) }
                                if element.kind == .text { TextOptionsBar(store: store, element: element) }
                            }
                            selectedTools
                        }.frame(maxHeight: .infinity, alignment: .bottom).padding(.bottom, 8)
                    }
                }
            }
            if showSlides { filmstrip }
        }
        .coordinateSpace(name: "editor-space")
        .overlay(alignment: .topLeading) {
            if let point = colorDropPosition {
                Circle().fill(Color(hex: store.pickerColor)).frame(width: 46, height: 46)
                    .overlay(Circle().stroke(.white, lineWidth: 2)).shadow(radius: 6)
                    .position(point).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            if colorDropThresholdActive {
                VStack(spacing: 7) {
                    GeometryReader { geometry in Color(hex: "3478F6").frame(width: geometry.size.width * store.fillThreshold, height: 3) }.frame(height: 3)
                    Text("ColorDrop threshold \(Int(store.fillThreshold * 100))%")
                        .font(.system(size: 12, weight: .medium)).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.8), in: Capsule())
                }.padding(.top, 58).allowsHitTesting(false)
            } else if store.isFilling || store.isSelectingPixels {
                ProgressView(store.isSelectingPixels ? "Selecting pixels…" : "Filling…").padding(12).background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 8)).padding(.top, 65)
            }
        }
        .overlay {
            if let point = store.clipboardMenuPoint {
                GeometryReader { geometry in
                    Color.black.opacity(0.001).contentShape(Rectangle()).onTapGesture { store.clipboardMenuPoint = nil }
                    ClipboardMenu(store: store)
                        .position(x: min(max(260, canvasFrame.minX + point.x / store.canvasSize.width * canvasFrame.width), geometry.size.width - 260),
                                  y: min(max(130, canvasFrame.minY + point.y / store.canvasSize.height * canvasFrame.height), geometry.size.height - 100))
                }
            }
        }
        .background(chrome)
        .foregroundStyle(Color(white: 0.78))
        .tint(accent)
        .preferredColorScheme(.dark)
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .sheet(item: $textEditor) { request in TextEditorSheet(store: store, element: request.element).id(request.id).presentationDetents([.medium, .large]) }
        .sheet(item: $videoPreview) { item in VideoPreviewSheet(url: item.url, name: item.name, options: item.options) }
        .sheet(isPresented: $showHelp) { helpSheet }
        .sheet(isPresented: $showDimensions) { PresentationDimensionsPanel(store: store) }
        .sheet(isPresented: $showPressure) { PressureCurvePanel(store: store) }
        .sheet(isPresented: $showGallery) { gallery }
        .overlay(alignment: .top) {
            if let message = store.statusText {
                Text(message).font(.system(size: 12, weight: .medium)).padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.black.opacity(0.85), in: Capsule()).padding(.top, 65).allowsHitTesting(false)
            }
        }
        .fullScreenCover(isPresented: $showPresentation) { PresentationView(store: store, startingAt: store.active) }
        .alert("Name your presentation", isPresented: $showRename) {
            TextField("Presentation name", text: $renamedTitle)
            Button("Cancel", role: .cancel) {}
            Button("Save") { if !renamedTitle.trimmingCharacters(in: .whitespaces).isEmpty { store.checkpoint(); store.deck.title = renamedTitle; store.save() } }
        }
        .alert("Something needs attention", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .modifier(KeynoteExportModifier(store: store, showKeynoteInfo: $showKeynoteInfo) { data in
            exportDocument = DeckDocument(data: data); exportContentType = UTType(filenameExtension: "pptx")!; showExporter = true
        })
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importPurpose == .deck ? [.json] : importPurpose == .video ? [.movie] : [.image]) { result in
            switch result {
            case .success(let url):
                if importPurpose == .deck { store.importDeck(url) }
                else { store.importMedia(url, kind: importPurpose == .video ? .video : .image) }
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .any(of: [.images, .videos]), preferredItemEncoding: .current)
        .onChange(of: photoItem) { _, item in
            Task {
                do {
                    if let item, item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                        if let movie = try await item.loadTransferable(type: PickedMovie.self) {
                            store.importMedia(movie.url, kind: .video); try? FileManager.default.removeItem(at: movie.url)
                        }
                    } else if let data = try await item?.loadTransferable(type: Data.self) { store.storeImage(data) }
                    photoItem = nil
                }
                catch { store.errorMessage = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $showExporter, document: exportDocument, contentType: exportContentType, defaultFilename: store.deck.title + (exportContentType == .json ? ".handwritten" : "")) { result in
            switch result {
            case .success(let url): store.notify("Saved " + url.lastPathComponent)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .task { await store.importBundledBrushesIfNeeded() }
        .onReceive(store.textEditRequests) { id in
            if let element = store.editableElements.first(where: { $0.id == id }) { edit(element) }
        }
        .onChange(of: store.active) { store.clipboardMenuPoint = nil }
        .onChange(of: scenePhase) { _, phase in if phase != .active { store.saveNow() } }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            Button { showGallery = true } label: { Text("Gallery").font(.system(size: 17, weight: .medium)).padding(.horizontal, 10) }.accessibilityLabel("Gallery")
            Button { showActions.toggle() } label: {
                Image(systemName: "wrench").font(.system(size: 20, weight: .regular)).symbolRenderingMode(.monochrome)
                    .frame(width: 44, height: 48).contentTransition(.identity)
            }.accessibilityLabel("Actions").popover(isPresented: $showActions, arrowEdge: .top) { actionsPanel }
            Menu {
                Button("Text", systemImage: "textformat") { textEditor = TextEditorRequest(element: nil) }
                Button("Photo library", systemImage: "photo.on.rectangle") { showPhotoPicker = true }
                Button("Image or GIF from Files", systemImage: "photo") { importPurpose = .image; showImporter = true }
                Button("Video from Files", systemImage: "video") { importPurpose = .video; showImporter = true }
            } label: { Image(systemName: "plus").font(.system(size: 23)).frame(width: 44, height: 48) }.accessibilityLabel("Insert text, image, GIF, or video")
            toolButton("lasso", label: "Selection tool", active: store.tool == .select) { store.setTool(store.tool == .select ? .draw : .select) }
            toolButton("cursorarrow", label: "Transform tool", active: store.tool == .transform) { store.setTool(store.tool == .transform ? .draw : .transform) }
            Spacer(minLength: 12)
            toolButton("rectangle.stack", label: showSlides ? "Hide slides" : "Show slides") { withAnimation(.easeInOut(duration: 0.2)) { showSlides.toggle() } }
            toolButton("play", label: "Present slides") { showPresentation = true }
            Rectangle().fill(.white.opacity(0.1)).frame(width: 1, height: 20).padding(.horizontal, 6)
            toolButton("paintbrush.pointed.fill", label: "Brush library", active: store.tool == .draw) {
                if store.tool == .draw { showBrushes.toggle() } else { store.setTool(.draw) }
            }.popover(isPresented: $showBrushes, arrowEdge: .top) { BrushLibraryPanel(store: store) { showBrushes = false; showPressure = true } }
            toolButton("eraser.fill", label: "Eraser library", active: store.tool == .erase) {
                if store.tool == .erase { showErasers.toggle() } else { store.setTool(.erase) }
            }.popover(isPresented: $showErasers, arrowEdge: .top) { BrushLibraryPanel(store: store, isEraser: true) { showErasers = false; showPressure = true } }
            toolButton("square.3.layers.3d", label: "Layers") { showLayers.toggle() }.popover(isPresented: $showLayers, arrowEdge: .top) { LayersPanel(store: store) }
            ColorDropControl(store: store, canvasFrame: canvasFrame, visibleFrame: viewportFrame, dropPosition: $colorDropPosition, thresholdActive: $colorDropThresholdActive) { showColors.toggle() }
                .popover(isPresented: $showColors, arrowEdge: .top) { ColorsPanel(store: store) }
        }.buttonStyle(.plain).padding(.horizontal, 15).frame(height: 58).background(chrome)
    }

    private var actionsPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Actions").font(.system(size: 22, weight: .bold)).padding(.horizontal, 12).padding(.bottom, 10)
            actionRow("New presentation", icon: "doc.badge.plus") { store.startBlankDeck() }
            actionRow("Rename", icon: "pencil") { renamedTitle = store.deck.title; showRename = true }
            actionRow("Export editable deck", icon: "square.and.arrow.up") { export() }
            actionRow("Export for Keynote", icon: "rectangle.on.rectangle") { showKeynoteInfo = true }
            actionRow("Open deck", icon: "folder") { importPurpose = .deck; showImporter = true }
            Divider().padding(.vertical, 8)
            actionRow("Copy & Paste", icon: "doc.on.clipboard") { store.showClipboard() }
            actionRow("Presentation size", icon: "aspectratio") { showDimensions = true }
            actionRow("Pressure curve", icon: "pencil.tip.crop.circle") { showPressure = true }
            actionRow("Apple Pencil only", icon: store.pencilOnly ? "checkmark.square" : "square") { store.pencilOnly.toggle() }
            actionRow("Help", icon: "questionmark.circle") { showHelp = true }
        }.padding(16).frame(width: 290).background(Color(white: 0.145)).buttonStyle(.plain).preferredColorScheme(.dark)
            .onDisappear { let action = pendingAction; pendingAction = nil; action?() }
    }
    private func actionRow(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button { pendingAction = action; showActions = false } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18)).frame(width: 24).foregroundStyle(accent)
                Text(title).font(.system(size: 15)); Spacer()
            }.padding(.horizontal, 12).frame(height: 42).contentShape(Rectangle())
        }
    }

    private func toolButton(_ icon: String, label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 22, weight: .regular)).foregroundStyle(active ? accent : Color(white: 0.75)).frame(width: 44, height: 48) }
            .accessibilityLabel(label)
            .accessibilityAddTraits(active ? .isSelected : [])
    }

    private var workspaceGrid: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color(white: 0.145)))
            var lines = Path()
            for x in stride(from: 0.0, through: size.width, by: 24) { lines.move(to: CGPoint(x: x, y: 0)); lines.addLine(to: CGPoint(x: x, y: size.height)) }
            for y in stride(from: 0.0, through: size.height, by: 24) { lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: size.width, y: y)) }
            context.stroke(lines, with: .color(.white.opacity(0.025)), lineWidth: 0.7)
        }
        .onTapGesture { store.selected = nil }
    }

    private func editorCanvas(scale: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color(hex: store.slide.paper)
            ForEach(store.layers) { layer in
                if layer.visible {
                    ZStack(alignment: .topLeading) {
                        EditableLayerElements(slide: store.slide, layer: layer, store: store, animateImages: !showPresentation && scenePhase == .active).allowsHitTesting(false)
                        if layer.id == store.activeLayer.id {
                            DrawingCanvas(store: store, scale: scale).id(store.slide.id).frame(width: store.canvasSize.width, height: store.canvasSize.height).blendMode(store.tool == .erase && (store.activeImportedBrush != nil || store.eraserBrush.usesGraphiteRenderer) ? .destinationOut : .normal)
                            if let mark = store.liveEraser { EraserShape(mark: mark).blendMode(.destinationOut).allowsHitTesting(false) }
                        }
                    }.frame(width: store.canvasSize.width, height: store.canvasSize.height).compositingGroup().opacity(layer.opacity).blendMode(layer.blendMode.blend)
                        .allowsHitTesting(layer.id == store.activeLayer.id)
                }
            }
            if !store.activeLayer.visible { DrawingCanvas(store: store, scale: scale).id(store.slide.id).frame(width: store.canvasSize.width, height: store.canvasSize.height).blendMode(store.tool == .erase && (store.activeImportedBrush != nil || store.eraserBrush.usesGraphiteRenderer) ? .destinationOut : .normal) }
            SelectionOverlay(store: store, scale: scale)
        }
        .frame(width: store.canvasSize.width, height: store.canvasSize.height).clipped()
        .accessibilityIdentifier("slide-canvas")
    }

    private var drawingControls: some View {
        VStack(spacing: 10) {
            BrushSizeControl(store: store)
            Button { store.setTool(store.tool == .eyedropper ? .draw : .eyedropper) } label: {
                Image(systemName: "square").font(.system(size: 16)).foregroundStyle(store.tool == .eyedropper ? accent : .gray).frame(width: 40, height: 35)
            }.accessibilityLabel("Eyedropper")
            StudioVerticalSlider(value: Binding(get: { store.tool == .erase ? store.eraserOpacity : store.opacity }, set: { if store.tool == .erase { store.eraserOpacity = $0 } else { store.opacity = $0 } }), range: 0.01...1, label: store.tool == .erase ? "Eraser opacity" : "Brush opacity")
            Button { store.canvasCommands.send(.undo) } label: { Image(systemName: "arrow.uturn.backward").frame(width: 40, height: 36) }.disabled(!store.canUndo).accessibilityLabel("Undo")
            Button { store.canvasCommands.send(.redo) } label: { Image(systemName: "arrow.uturn.forward").frame(width: 40, height: 36) }.disabled(!store.canRedo).accessibilityLabel("Redo")
        }.buttonStyle(.plain).padding(.vertical, 10).frame(width: 44)
            .background(Color(white: 0.09).opacity(0.94), in: RoundedRectangle(cornerRadius: 6))
    }

    private var selectedTools: some View {
        HStack(spacing: 14) {
            if store.tool == .select {
                ForEach(SelectionShape.allCases, id: \.self) { shape in
                    Button(shape.rawValue) { store.selectionShape = shape }.foregroundStyle(store.selectionShape == shape ? accent : .gray)
                }
                Divider().frame(height: 24)
                Button("All") { store.selectedIDs = Set(store.editableElements.map(\.id)) }
                Button("Invert") { store.invertSelection() }
                Button("Clear") { store.selected = nil }
                Button("Transform") { store.setTool(.transform) }.disabled(store.selectedIDs.isEmpty)
            } else {
                Button("Freeform") { store.uniformTransform = false }.foregroundStyle(!store.uniformTransform ? accent : .gray)
                Button("Uniform") { store.uniformTransform = true }.foregroundStyle(store.uniformTransform ? accent : .gray)
                Divider().frame(height: 24)
                Button { store.flipSelection(horizontal: true) } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.accessibilityLabel("Flip horizontal")
                Button { store.flipSelection(horizontal: false) } label: { Image(systemName: "arrow.up.and.down.righttriangle.up.righttriangle.down") }.accessibilityLabel("Flip vertical")
                Button { store.rotateSelection() } label: { Image(systemName: "rotate.right") }.accessibilityLabel("Rotate 90 degrees")
                Button { store.duplicateElement() } label: { Image(systemName: "plus.square.on.square") }.accessibilityLabel("Duplicate selection")
                if store.selectedIDs.count == 1, let selected = store.selectedElement, selected.kind == .text || selected.kind == .video {
                    Button { edit(selected) } label: { Image(systemName: selected.kind == .text ? "pencil" : "play.fill") }.accessibilityLabel(selected.kind == .text ? "Edit text" : "Play video")
                }
                Button { showProperties = true } label: { Image(systemName: "slider.horizontal.3") }.accessibilityLabel("Element properties")
                    .popover(isPresented: $showProperties) { elementProperties }
                Menu { elementOrdering } label: { Image(systemName: "ellipsis").frame(width: 28, height: 36) }.accessibilityLabel("Element actions")
                Button(role: .destructive) { store.deleteElement() } label: { Image(systemName: "trash") }.accessibilityLabel("Delete selection")
            }
            Text("\(store.selectedIDs.count) selected").foregroundStyle(.gray)
        }.font(.system(size: 12, weight: .medium)).buttonStyle(.plain).padding(.horizontal, 20).frame(height: 48)
            .background(Color(white: 0.09).opacity(0.97), in: RoundedRectangle(cornerRadius: 8))
    }

    private var filmstrip: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 15) {
                    ForEach(Array(store.deck.slides.enumerated()), id: \.element.id) { index, slide in
                        Button { store.selectSlide(index) } label: {
                            VStack(spacing: 6) {
                                SlideThumbnail(slide: slide, store: store).equatable()
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(index == store.active ? accent : .white.opacity(0.12), lineWidth: index == store.active ? 2 : 1).padding(-3))
                                Text(String(format: "%02d", index + 1)).font(.system(size: 10, design: .monospaced)).foregroundStyle(index == store.active ? .white : .gray)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Slide \(index + 1): \(slide.name)")
                        .accessibilityAddTraits(index == store.active ? .isSelected : [])
                        .onDrag { draggedSlideID = slide.id; return NSItemProvider(object: slide.id.uuidString as NSString) }
                        .onDrop(of: [.text], delegate: SlideReorderDrop(store: store, target: slide.id, dragged: $draggedSlideID, highlighted: $dropSlideID))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(dropSlideID == slide.id ? accent : .clear, lineWidth: 3).padding(-6))
                        .contextMenu {
                            Button("Duplicate slide", systemImage: "plus.square.on.square") { store.selectSlide(index); store.duplicateSlide() }
                            Button("Move earlier", systemImage: "arrow.left") { store.selectSlide(index); store.moveSlide(-1) }.disabled(index == 0)
                            Button("Move later", systemImage: "arrow.right") { store.selectSlide(index); store.moveSlide(1) }.disabled(index == store.deck.slides.count - 1)
                            Button("Delete slide", systemImage: "trash", role: .destructive) { store.selectSlide(index); store.deleteSlide() }.disabled(store.deck.slides.count == 1)
                        }
                    }
                    Button { store.addSlide() } label: { Image(systemName: "plus").font(.system(size: 20, weight: .light)).frame(width: 70, height: 60).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 4)).overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3]))).padding(.bottom, 18) }.accessibilityLabel("New slide")
                }
                .padding(.horizontal, 26).padding(.top, 13).padding(.bottom, 9)
            }
            Menu {
                if !store.selectedIDs.isEmpty { Section("Selected elements") { elementOrdering } }
                Button("New slide", systemImage: "plus") { store.addSlide() }
                Button("Duplicate slide", systemImage: "plus.square.on.square") { store.duplicateSlide() }
                Button("Move earlier", systemImage: "arrow.left") { store.moveSlide(-1) }.disabled(store.active == 0)
                Button("Move later", systemImage: "arrow.right") { store.moveSlide(1) }.disabled(store.active == store.deck.slides.count - 1)
                Button("Delete slide", systemImage: "trash", role: .destructive) { store.deleteSlide() }.disabled(store.deck.slides.count == 1)
            } label: { Image(systemName: "ellipsis").frame(width: 52, height: 60) }.accessibilityLabel("Slide actions")
        }
        .frame(height: 110)
        .background(chrome)
    }

    private var elementOrdering: some View {
        ForEach(ElementOrder.allCases, id: \.self) { order in
            Button(order.rawValue, systemImage: order.icon) { store.orderSelection(order) }
        }
    }

    private var elementProperties: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Element").font(.system(size: 21, weight: .semibold))
            Text("Rotation").font(.caption).foregroundStyle(.secondary)
            Slider(value: Binding(get: { store.selectedElement?.rotation ?? 0 }, set: { value in if var e = store.selectedElement { e.rotation = value; store.update(e) } }), in: -180...180, onEditingChanged: { editing in if editing { store.checkpoint() } else { store.save() } }).accessibilityLabel("Element rotation")
            HStack {
                Button("Backward", systemImage: "square.3.layers.3d.bottom.filled") { store.moveLayer(-1) }
                Button("Forward", systemImage: "square.3.layers.3d.top.filled") { store.moveLayer(1) }
            }.font(.system(size: 12))
        }.padding(24).frame(width: 300).preferredColorScheme(.dark)
    }
    private var gallery: some View {
        NavigationStack {
            List {
                Section {
                    Button { store.startBlankDeck(); showGallery = false } label: { Label("New blank presentation", systemImage: "plus") }
                    Button { showGallery = false } label: { Label("Continue \(store.deck.title)", systemImage: "doc") }
                }
                Section("Saved presentations") {
                    ForEach(store.savedDecks) { saved in
                        Button { store.openSavedDeck(saved); showGallery = false } label: {
                            HStack { Image(systemName: "rectangle.stack"); VStack(alignment: .leading) { Text(saved.title); Text(saved.date, style: .date).font(.caption).foregroundStyle(.secondary) } }
                        }
                    }
                }
            }.navigationTitle("Gallery").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showGallery = false } } }
        }.preferredColorScheme(.dark)
    }
    private var helpSheet: some View {
        NavigationStack {
            List {
                Section("Drawing") { Text("Tap the brush again to open the library. Use the left sliders for size and opacity. Tilt Apple Pencil with a pencil or crayon brush to shade. Adjust the pressure curve in Actions → Pressure curve.") }
                Section("Gestures") { Text("Double-tap the side of a supported Apple Pencil to switch between brush and eraser. Enable Double Tap in iPad Settings → Apple Pencil. Pinch with two fingers to zoom; drag with two fingers to pan. Tap the zoom percentage to fit the canvas. Tap with two fingers to undo, or three fingers to redo. Swipe three fingers down for Cut, Copy, Copy All, Duplicate, Cut & Paste, and Paste. Actions → Copy & Paste opens the same menu. Duplicate, Cut & Paste, and Paste create a layer above the active layer. The arrows on the left do the same. Hold a finger or Apple Pencil still on the canvas, then slide to pick a color and release. The square between the sliders also activates the eyedropper.") }
                Section("Selection & transform") { Text("Draw a lasso or choose Rectangle or Ellipse to select drawing pixels and objects. Drawing pixels are flattened; text and media remain editable. Tap the arrow to transform the selection: drag to move, use the eight handles to resize, or the top handle to rotate. Uniform keeps proportions. Freeform changes width and height independently. Select text, then tap it again to edit. Drag its side handles to wrap at a new width, use the text toolbar for font and size, or the color circle to recolor selected text. Selected videos have Play/Pause, speed, start, loop, and audio controls above the selection toolbar. Tap a selected video again to play or pause it on the editing canvas.") }
                Section("Layers & erasing") { Text("Create layers with + in Layers. All new marks go into the active layer. Tap N for blend modes; adjust opacity, visibility, and locking there. Tap the eraser again for its brush library. Erasing affects only the active layer, and later strokes can paint over erased areas.") }
                Section("Slides") { Text("Hold a slide thumbnail still for its menu, or hold and drag it onto another thumbnail to reorder. Use + to add text, images, GIFs, and video. Animated GIFs loop automatically on the canvas and while presenting. The stacked rectangles show or hide slides. Tap Play to present. Gallery creates a blank presentation and keeps your previous deck available.") }
                Section("Brushes") { Text("The app uses PencilKit brushes and retains pressure and tilt data. Import .brush and .brushset files from the brush library. Imported brushes use their tip, grain, spacing, and basic pressure settings; advanced Procreate wet mixing and color dynamics may differ. Smudge and warp are not implemented.") }
            }.navigationTitle("SlideSketch").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showHelp = false } } }
        }.preferredColorScheme(.dark)
    }
    private func edit(_ element: SlideElement) {
        if element.kind == .text { textEditor = TextEditorRequest(element: element) }
        if element.kind == .video, let asset = element.asset, let url = store.assetURL(asset) { videoPreview = VideoPreviewItem(url: url, name: element.name, options: element.videoOptions ?? VideoOptions()) }
    }
    private func export() {
        do { exportDocument = DeckDocument(data: try store.exportDeck()); exportContentType = .json; showExporter = true }
        catch { store.errorMessage = error.localizedDescription }
    }
}

struct TextEditorSheet: View {
    @ObservedObject var store: DeckStore
    var element: SlideElement?
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var font = "Georgia"
    @State private var size = 64.0
    @State private var color = Color(hex: "24483E")
    init(store: DeckStore, element: SlideElement?) {
        self.store = store; self.element = element
        _text = State(initialValue: element?.text ?? "")
        _font = State(initialValue: element?.font ?? "Georgia")
        _size = State(initialValue: element?.fontSize ?? 64)
        _color = State(initialValue: Color(hex: element?.color ?? store.ink))
    }
    var body: some View {
        NavigationStack {
            Form {
                TextEditor(text: $text).frame(minHeight: 120).font(.custom(font, size: 26)).accessibilityLabel("Slide text")
                Picker("Typeface", selection: $font) { Text("Serif").tag("Georgia"); Text("Sans").tag("AvenirNext-Regular"); Text("Handwritten").tag("Noteworthy-Light") }.pickerStyle(.segmented)
                HStack { Text("Size"); Slider(value: $size, in: 8...240); Text("\(Int(size))").monospacedDigit() }
                ColorPicker("Color", selection: $color, supportsOpacity: false)
            }
            .navigationTitle(element == nil ? "Add text" : "Edit text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { commit() }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            }
        }
    }
    private func commit() {
        store.saveText(text, font: font, size: size, color: color.rgbHex, editing: element?.id)
        dismiss()
    }
}

struct VideoPreviewItem: Identifiable { let id = UUID(); var url: URL; var name: String; var options: VideoOptions }
struct VideoPreviewSheet: View {
    var url: URL
    var name: String
    var options: VideoOptions
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            InlineVideo(url: url, options: options, preview: true).navigationTitle(name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

struct PresentationView: View {
    @ObservedObject var store: DeckStore
    var startingAt: Int
    @State private var index: Int
    init(store: DeckStore, startingAt: Int) {
        self.store = store; self.startingAt = startingAt; _index = State(initialValue: startingAt)
    }
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / store.canvasSize.width, geometry.size.height / store.canvasSize.height)
            ZStack {
                Color.black.ignoresSafeArea()
                StaticSlide(slide: store.deck.slides[index], store: store, presenting: true)
                    .id(store.deck.slides[index].id)
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: store.canvasSize.width * scale, height: store.canvasSize.height * scale, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .gesture(DragGesture(minimumDistance: 60).onEnded { value in if abs(value.translation.width) > abs(value.translation.height) { advance(value.translation.width < 0 ? 1 : -1) } })
                HStack(spacing: 20) {
                    Button { dismiss() } label: { Image(systemName: "xmark").frame(width: 36, height: 36) }.accessibilityLabel("Exit presentation")
                    Button { advance(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }.disabled(index == 0).accessibilityLabel("Previous slide")
                    Text("\(index + 1) / \(store.deck.slides.count)").font(.system(size: 12)).monospacedDigit()
                    Button { advance(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }.disabled(index == store.deck.slides.count - 1).accessibilityLabel("Next slide")
                }
                .buttonStyle(.plain).padding(.horizontal, 10).background(.ultraThinMaterial, in: Capsule()).padding(.bottom, 12).frame(maxHeight: .infinity, alignment: .bottom)
            }
        }.statusBarHidden().preferredColorScheme(.dark)
    }
    private func advance(_ step: Int) { index = min(store.deck.slides.count - 1, max(0, index + step)) }
}

#Preview { ContentView() }
