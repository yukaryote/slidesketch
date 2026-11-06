import SwiftUI
import PencilKit
import UniformTypeIdentifiers
import AVFoundation
import Combine

enum StudioPalette {
    static let ink = Color(hex: "24483E")
    static let muted = Color(hex: "85917C")
    static let chrome = Color(hex: "F8F8F2")
    static let workspace = Color(hex: "ECEEE6")
    static let line = Color(hex: "DCE1D3")
    static let colors = ["24483E", "7F956B", "D98664", "E7BC5D", "81969A", "EEE4D0"]
    static let papers = ["FBF5E9", "E7ECDF", "F1DDD0", "DFE9E8", "FFFFFF"]
}

extension Color {
    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x24483E
        self.init(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

nonisolated enum ElementKind: String, Codable { case text, image, video, ink, artwork, erase, fill }
nonisolated struct SlideElement: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var kind: ElementKind
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    var rotation: Double = 0
    var text: String = ""
    var font: String = "Georgia"
    var fontSize: Double = 64
    var color: String = "24483E"
    var asset: String? = nil
    var drawing: Data? = nil
    var name: String = "Element"
    var inkPreviewVersion: Int? = nil
    var flipX: Bool? = nil
    var flipY: Bool? = nil
    var layerID: UUID? = nil
    var eraser: EraserMark? = nil
    var fillBehind: Bool? = nil
    var videoOptions: VideoOptions? = nil
    var fillRegionID: String? = nil
    var lineworkAsset: String? = nil

    static func text(_ value: String, x: Double, y: Double, width: Double, size: Double, font: String = "Georgia", color: String = "24483E") -> Self {
        Self(kind: .text, x: x, y: y, width: width, height: Double(value.components(separatedBy: "\n").count) * size * 1.2, text: value, font: font, fontSize: size, color: color, name: "Text")
    }
    static func art(_ name: String, x: Double, y: Double, width: Double, height: Double, rotation: Double = 0) -> Self {
        Self(kind: .artwork, x: x, y: y, width: width, height: height, rotation: rotation, name: name)
    }
}

nonisolated struct StudioSlide: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var paper: String = "FFFFFF"
    var elements: [SlideElement] = []
    var layers: [StudioLayer]? = [StudioLayer()]
    var referenceLayerID: UUID? = nil
}

nonisolated struct StudioDeck: Codable, Sendable {
    var version = 2
    var title: String
    var slides: [StudioSlide]
    var defaultPaper: String? = nil
    var dimensions: PresentationDimensions? = nil

    static var blank: Self {
        Self(title: "Untitled presentation", slides: [StudioSlide(name: "Slide 1")])
    }
}

nonisolated enum BrushCategory: String, CaseIterable, Identifiable {
    case basic = "Basic", sketching = "Sketching", inking = "Inking", drawing = "Drawing", painting = "Painting"
    var id: String { rawValue }
    var icon: String { switch self { case .basic: "circle.fill"; case .sketching: "pencil.tip"; case .inking: "drop.fill"; case .drawing: "pencil.and.outline"; case .painting: "paintbrush.fill" } }
}

nonisolated enum StudioBrush: String, CaseIterable, Identifiable, Codable {
    case round, flat, graphite, pencil, ink, monoline, marker, crayon, watercolor
    var id: String { rawValue }
    var title: String { switch self {
        case .round: "Round"; case .flat: "Flat"; case .graphite: "Soft Graphite"; case .pencil: "Fine Pencil"; case .ink: "Fountain Pen"
        case .monoline: "Studio Pen"; case .marker: "Felt Marker"; case .crayon: "Wax Crayon"; case .watercolor: "Watercolor"
    } }
    var category: BrushCategory { switch self {
        case .round, .flat: .basic; case .graphite, .pencil: .sketching; case .ink, .monoline: .inking
        case .marker, .crayon: .drawing; case .watercolor: .painting
    } }
    var supportsTilt: Bool { self == .graphite || self == .pencil || self == .crayon }
    var inkType: PKInkingTool.InkType { switch self {
        case .round: .monoline; case .flat: .marker; case .graphite, .pencil: .pencil; case .ink: .fountainPen; case .monoline: .monoline
        case .marker: .marker; case .crayon: .crayon; case .watercolor: .watercolor
    } }
    var defaultSize: Double { switch self {
        case .round: 16; case .flat: 30; case .graphite: 8; case .pencil: 3; case .ink: 9; case .monoline: 5
        case .marker: 24; case .crayon: 24; case .watercolor: 50
    } }
}

enum EditorTool { case draw, erase, select, transform, eyedropper }
enum CanvasCommand { case undo, redo, finishStroke }
enum BackgroundScope: String, CaseIterable, Identifiable {
    case currentSlide = "Current slide", allSlides = "All slides"
    var id: String { rawValue }
}
enum SelectionShape: String, CaseIterable { case freehand = "Freehand", rectangle = "Rectangle", ellipse = "Ellipse" }
struct SavedDeck: Identifiable { var id: URL; var title: String; var date: Date }

// Slide ink is artwork on a fixed paper color, independent of the editor chrome.
enum SlideInkRendering {
    static let appearance: UIUserInterfaceStyle = .light
    static let previewVersion = 1

    static func pngData(for drawing: PKDrawing, in bounds: CGRect) -> Data? {
        guard !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0,
              bounds.width < 20000, bounds.height < 20000 else { return nil }
        var data: Data?
        UITraitCollection(userInterfaceStyle: appearance).performAsCurrent {
            data = drawing.image(from: bounds, scale: 1.5).pngData()
        }
        return data
    }
}

struct DeckPackage: Codable {
    var deck: StudioDeck
    var assets: [String: Data]
}

struct DeckDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json, UTType(filenameExtension: "pptx")!] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

@MainActor
final class DeckStore: ObservableObject {
    @Published var deck: StudioDeck { didSet { deckRevision &+= 1 } }
    var deckRevision = 0
    let transformPreview = CanvasTransformPreview()
    let fillCache = LineworkFillCache()
    let previewCache = SlidePreviewCache()
    let rasterCache = RasterImageCache()
    @Published var isFilling = false
    @Published var isSelectingPixels = false
    @Published var fillThreshold = UserDefaults.standard.object(forKey: "ColorDropThreshold") as? Double ?? 0.2 { didSet { UserDefaults.standard.set(fillThreshold, forKey: "ColorDropThreshold") } }
    @Published var active = 0
    @Published var activeLayerID: UUID?
    @Published var liveEraser: EraserMark?
    @Published var eraserBrush: StudioBrush = .round
    @Published var eraserSize: Double = 30
    @Published var eraserOpacity: Double = 1
    @Published var sizeBookmarks = BrushSizeBookmarks.load() { didSet { sizeBookmarks.save() } }
    @Published var stabilization: Double = UserDefaults.standard.object(forKey: "StrokeStabilization") as? Double ?? 0.3 { didSet { UserDefaults.standard.set(stabilization, forKey: "StrokeStabilization") } }
    @Published var editorVideoID: UUID?
    @Published var editorVideoPaused = false
    @Published var selectedIDs: Set<UUID> = [] {
        didSet { if let id = editorVideoID, !selectedIDs.contains(id) { editorVideoID = nil; editorVideoPaused = false } }
    }
    @Published var tool: EditorTool = .draw
    @Published var selectionShape: SelectionShape = .freehand
    @Published var uniformTransform = true
    @Published var lassoPoints: [CGPoint] = []
    @Published var eyedropperPoint: CGPoint?
    @Published var sampledColor = "111111"
    @Published var recentColors: [String] = []
    @Published var statusText: String?
    let canvasCommands = PassthroughSubject<CanvasCommand, Never>()
    let canvasInteraction = PassthroughSubject<Void, Never>()
    let textEditRequests = PassthroughSubject<UUID, Never>()
    @Published var clipboardMenuPoint: CGPoint?
    var colorEditIDs: Set<UUID> = []
    var colorEditCheckpointed = false
    var selected: UUID? {
        get { slide.elements.first { selectedIDs.contains($0.id) }?.id }
        set { selectedIDs = newValue.map { [$0] } ?? [] }
    }
    var isDrawing: Bool {
        get { tool == .draw }
        set { tool = newValue ? .draw : .transform }
    }
    @Published var importedBrushes: [ImportedBrush] = []
    @Published var importedBrushID: UUID?
    @Published var importedEraserID: UUID?
    @Published var brush: StudioBrush = .graphite
    @Published var brushSize: Double = 8
    @Published var pressureCurve = PressureCurve.load() { didSet { pressureCurve.save() } }
    @Published var opacity: Double = 1
    @Published var ink = "111111"
    @Published var pencilOnly = false
    @Published var errorMessage: String?
    @Published var saveMessage = "Saved on this iPad"
    @Published var canUndo = false
    @Published var canRedo = false
    private var past: [StudioDeck] = []
    private var future: [StudioDeck] = []
    private var pendingSave: DispatchWorkItem?
    private var saveGeneration = 0
    private lazy var persistence = DeckPersistence(url: deckURL)
    let documents: URL
    let mediaFolder: URL
    private let deckURL: URL
    private var toastTask: DispatchWorkItem?

    init(directory: URL? = nil) {
        documents = directory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        mediaFolder = documents.appendingPathComponent("Media", isDirectory: true)
        deckURL = documents.appendingPathComponent("CurrentDeck.json")
        var loaded = StudioDeck.blank
        do {
            try FileManager.default.createDirectory(at: mediaFolder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: deckURL.path) {
                let candidate = try JSONDecoder().decode(StudioDeck.self, from: Data(contentsOf: deckURL))
                if !candidate.slides.isEmpty { loaded = candidate }
            }
        } catch { saveMessage = "Could not load saved deck"; errorMessage = error.localizedDescription }
        deck = Self.withLayers(loaded)
        loadImportedBrushes()
        do {
            if let refreshed = try refreshingInkPreviews(in: deck) {
                deck = refreshed
                saveNow()
            }
        } catch { errorMessage = "Could not refresh saved ink: " + error.localizedDescription }
        saveNow()
    }

    var slide: StudioSlide { deck.slides[active] }
    var selectedElement: SlideElement? { slide.elements.first { $0.id == selected } }

    func checkpoint() {
        past.append(deck)
        if past.count > 250 { past.removeFirst() }
        future.removeAll()
        updateHistory()
    }
    private func updateHistory() { canUndo = !past.isEmpty; canRedo = !future.isEmpty }
    func undo() {
        guard let previous = past.popLast() else { return }
        let selectedSlide = slide.id
        future.append(deck); deck = previous
        active = deck.slides.firstIndex { $0.id == selectedSlide } ?? min(active, deck.slides.count - 1); selected = nil
        updateHistory(); save(); notify("Undo")
    }
    func redo() {
        guard let next = future.popLast() else { return }
        let selectedSlide = slide.id
        past.append(deck); deck = next
        active = deck.slides.firstIndex { $0.id == selectedSlide } ?? min(active, deck.slides.count - 1); selected = nil
        updateHistory(); save(); notify("Redo")
    }
    func save() {
        pendingSave?.cancel(); saveGeneration &+= 1
        if saveMessage != "Saving on this iPad…" { saveMessage = "Saving on this iPad…" }
        let generation = saveGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.saveGeneration == generation else { return }
            self.persistence.save(self.deck) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, self.saveGeneration == generation else { return }
                    self.saveMessage = error == nil ? "Saved on this iPad" : "Unable to save"
                    if let error { self.errorMessage = error }
                }
            }
        }
        pendingSave = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
    func saveNow() {
        pendingSave?.cancel(); pendingSave = nil; saveGeneration &+= 1
        do { try persistence.flush(deck); saveMessage = "Saved on this iPad" }
        catch { saveMessage = "Unable to save"; errorMessage = error.localizedDescription }
    }
    func selectSlide(_ index: Int) { active = index; activeLayerID = nil; selected = nil; liveEraser = nil }
    func addSlide() { checkpoint(); active += 1; deck.slides.insert(StudioSlide(name: "Slide \(deck.slides.count + 1)", paper: deck.defaultPaper ?? "FFFFFF"), at: active); selected = nil; save() }
    func duplicateSlide() {
        checkpoint(); var copy = slide; copy.id = UUID(); copy.name += " · copy"
        copy.elements = copy.elements.map { var e = $0; e.id = UUID(); return e }
        active += 1; deck.slides.insert(copy, at: active); selected = nil; save()
    }
    func deleteSlide() {
        guard deck.slides.count > 1 else { return }
        checkpoint(); deck.slides.remove(at: active); active = min(active, deck.slides.count - 1); selected = nil; save()
    }
    func moveSlide(_ direction: Int) {
        let target = active + direction
        guard deck.slides.indices.contains(target) else { return }
        checkpoint(); deck.slides.swapAt(active, target); active = target; save()
    }
    func add(_ element: SlideElement, keepDrawing: Bool = false) {
        guard canEditActiveLayer else { notify("Choose a visible, unlocked layer"); return }
        var element = element; element.layerID = activeLayer.id
        checkpoint(); deck.slides[active].elements.append(element)
        if !keepDrawing { selected = element.id; isDrawing = false }
        save()
    }
    func update(_ element: SlideElement) {
        guard let index = deck.slides[active].elements.firstIndex(where: { $0.id == element.id }) else { return }
        deck.slides[active].elements[index] = element
    }
    func deleteElement() {
        guard canEditActiveLayer else { return }
        guard !selectedIDs.isEmpty else { return }
        checkpoint(); deck.slides[active].elements.removeAll { selectedIDs.contains($0.id) }
        selected = nil; save()
    }
    func duplicateElement() { performClipboard(.duplicate) }
    func notify(_ message: String) {
        toastTask?.cancel(); statusText = message
        let task = DispatchWorkItem { [weak self] in self?.statusText = nil }
        toastTask = task; DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: task)
    }
    func chooseColor(_ hex: String) {
        ink = hex
        recentColors.removeAll { $0 == hex }; recentColors.insert(hex, at: 0)
        recentColors = Array(recentColors.prefix(10))
    }
    func setTool(_ newTool: EditorTool) {
        tool = newTool; lassoPoints = []; eyedropperPoint = nil
        if newTool == .draw || newTool == .erase { selected = nil }
    }
    var savedDecks: [SavedDeck] {
        let folder = documents.appendingPathComponent("Decks")
        return ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []).compactMap { url in
            guard let data = try? Data(contentsOf: url), let deck = try? JSONDecoder().decode(StudioDeck.self, from: data) else { return nil }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return SavedDeck(id: url, title: deck.title, date: date)
        }.sorted { $0.date > $1.date }
    }
    private func archiveCurrentDeck() throws {
        let folder = documents.appendingPathComponent("Decks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(deck).write(to: folder.appendingPathComponent(UUID().uuidString + ".json"), options: .atomic)
    }
    func startBlankDeck() {
        do {
            try archiveCurrentDeck()
            checkpoint(); deck = .blank; activeLayerID = nil; active = 0; selected = nil; tool = .draw
            saveNow(); notify("New presentation")
        } catch { errorMessage = error.localizedDescription }
    }
    func openSavedDeck(_ saved: SavedDeck) {
        do {
            let candidate = try JSONDecoder().decode(StudioDeck.self, from: Data(contentsOf: saved.id))
            guard !candidate.slides.isEmpty else { return }
            try archiveCurrentDeck()
            checkpoint(); deck = Self.withLayers(candidate); activeLayerID = nil; active = 0; selected = nil; tool = .draw; saveNow()
        } catch { errorMessage = error.localizedDescription }
    }
    func moveLayer(_ direction: Int) {
        guard let index = slide.elements.firstIndex(where: { $0.id == selected }) else { return }
        let target = index + direction
        guard slide.elements.indices.contains(target) else { return }
        checkpoint(); deck.slides[active].elements.swapAt(index, target); save()
    }
    func setBackground(_ color: String, scope: BackgroundScope) {
        let hex = color.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard hex.count == 6, hex.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return }
        let targets = scope == .allSlides ? Array(deck.slides.indices) : [active]
        let changesDefault = scope == .allSlides && deck.defaultPaper != hex
        guard changesDefault || targets.contains(where: { deck.slides[$0].paper != hex }) else { return }
        checkpoint()
        for index in targets { deck.slides[index].paper = hex }
        if scope == .allSlides { deck.defaultPaper = hex }
        save()
        notify(scope == .allSlides ? "Background applied to all slides" : "Background applied to current slide")
    }
    func assetURL(_ asset: String) -> URL? {
        if asset.hasPrefix("bundle:") { return Bundle.main.url(forResource: String(asset.dropFirst(7)), withExtension: nil) }
        guard asset == URL(fileURLWithPath: asset).lastPathComponent else { return nil }
        return mediaFolder.appendingPathComponent(asset)
    }
    func storeImage(_ data: Data, name: String = "Image") {
        guard let imported = ImportedImage(data: data) else { errorMessage = "This image could not be opened."; return }
        do {
            let filename = UUID().uuidString + "." + imported.fileExtension
            try imported.data.write(to: mediaFolder.appendingPathComponent(filename), options: .atomic)
            let ratio = imported.size.width / max(1, imported.size.height)
            let w = min(800, canvasSize.width * 0.8, min(650, canvasSize.height * 0.8) * ratio), h = w / ratio
            add(SlideElement(kind: .image, x: (canvasSize.width - w) / 2, y: (canvasSize.height - h) / 2, width: w, height: h, asset: filename, name: name))
        } catch { errorMessage = error.localizedDescription }
    }
    func importMedia(_ url: URL, kind: ElementKind) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            if kind == .image { storeImage(try Data(contentsOf: url), name: url.lastPathComponent); return }
            let filename = UUID().uuidString + "." + url.pathExtension
            try FileManager.default.copyItem(at: url, to: mediaFolder.appendingPathComponent(filename))
            let w = min(800.0, canvasSize.width * 0.7, canvasSize.height * 0.7 * 16 / 9), h = w * 9 / 16
            add(SlideElement(kind: .video, x: (canvasSize.width - w) / 2, y: (canvasSize.height - h) / 2, width: w, height: h, asset: filename, name: url.lastPathComponent))
        } catch { errorMessage = error.localizedDescription }
    }
    func addDrawing(_ drawing: PKDrawing, on slideID: UUID? = nil, in layerID: UUID? = nil, named brushName: String? = nil) {
        let destinationID = layerID ?? activeLayer.id
        guard let destinationSlide = deck.slides.first(where: { $0.id == (slideID ?? slide.id) }),
              let layer = destinationSlide.layers?.first(where: { $0.id == destinationID }), layer.visible, !layer.locked else { return }
        let bounds = drawing.bounds.insetBy(dx: -4, dy: -4)
        guard !bounds.isNull, bounds.width > 0, bounds.height > 0, bounds.width < 20000, bounds.height < 20000 else { return }
        let normalized = drawing.transformed(using: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
        do {
            let filename = UUID().uuidString + ".png"
            let rect = CGRect(origin: .zero, size: bounds.size)
            guard let png = SlideInkRendering.pngData(for: normalized, in: rect) else { return }
            try png.write(to: mediaFolder.appendingPathComponent(filename), options: .atomic)
            guard let index = deck.slides.firstIndex(where: { $0.id == (slideID ?? slide.id) }) else { return }
            checkpoint()
            deck.slides[index].elements.append(SlideElement(kind: .ink, x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height, asset: filename, drawing: normalized.dataRepresentation(), name: (brushName ?? brush.title) + " stroke", inkPreviewVersion: SlideInkRendering.previewVersion, layerID: destinationID))
            save()
        } catch { errorMessage = error.localizedDescription }
    }
    private func refreshingInkPreviews(in source: StudioDeck) throws -> StudioDeck? {
        var refreshed = source
        var changed = false
        for s in refreshed.slides.indices {
            for e in refreshed.slides[s].elements.indices {
                let element = refreshed.slides[s].elements[e]
                guard element.kind == .ink, element.inkPreviewVersion != SlideInkRendering.previewVersion,
                      let data = element.drawing, let drawing = try? PKDrawing(data: data),
                      let png = SlideInkRendering.pngData(for: drawing, in: drawing.bounds.insetBy(dx: -4, dy: -4)) else { continue }
                // Rebuild from the original strokes, keeping transforms and ink opacity intact.
                // A new filename also avoids stale images in the in-memory asset cache.
                let filename = UUID().uuidString + ".png"
                try png.write(to: mediaFolder.appendingPathComponent(filename), options: .atomic)
                refreshed.slides[s].elements[e].asset = filename
                refreshed.slides[s].elements[e].inkPreviewVersion = SlideInkRendering.previewVersion
                changed = true
            }
        }
        return changed ? refreshed : nil
    }

    func exportDeck() throws -> Data {
        var assets: [String: Data] = [:]
        for asset in Set(deck.slides.flatMap(\.elements).flatMap { [$0.asset, $0.lineworkAsset].compactMap { $0 } }) {
            if let url = assetURL(asset) { assets[asset] = try Data(contentsOf: url) }
        }
        return try JSONEncoder().encode(DeckPackage(deck: deck, assets: assets))
    }
    func importDeck(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let package = try JSONDecoder().decode(DeckPackage.self, from: Data(contentsOf: url))
            guard (1...2).contains(package.deck.version), !package.deck.slides.isEmpty, package.deck.slides.count <= 200 else { throw CocoaError(.fileReadCorruptFile) }
            var imported = Self.withLayers(package.deck)
            var replacements: [String: String] = [:]
            for (key, data) in package.assets {
                let ext = URL(fileURLWithPath: key).pathExtension
                let safeName = UUID().uuidString + (ext.isEmpty ? "" : "." + ext)
                try data.write(to: mediaFolder.appendingPathComponent(safeName), options: .atomic)
                replacements[key] = safeName
            }
            for s in imported.slides.indices {
                guard imported.slides[s].elements.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.width.isFinite && $0.height.isFinite && $0.width > 0 && $0.height > 0 && $0.width < 20000 && $0.height < 20000 && $0.rotation.isFinite && $0.fontSize.isFinite && $0.fontSize > 0 && $0.fontSize < 2000 }) else { throw CocoaError(.fileReadCorruptFile) }
                for e in imported.slides[s].elements.indices {
                    if let old = imported.slides[s].elements[e].asset {
                        guard let new = replacements[old] else { throw CocoaError(.fileReadCorruptFile) }
                        imported.slides[s].elements[e].asset = new
                    }
                    if let old = imported.slides[s].elements[e].lineworkAsset {
                        guard let new = replacements[old] else { throw CocoaError(.fileReadCorruptFile) }
                        imported.slides[s].elements[e].lineworkAsset = new
                    }
                }
            }
            imported = try refreshingInkPreviews(in: imported) ?? imported
            checkpoint(); deck = imported; activeLayerID = nil; active = 0; selected = nil; save()
        } catch { errorMessage = "This deck could not be opened: " + error.localizedDescription }
    }
}

extension Color {
    var rgbHex: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()))
    }
}
