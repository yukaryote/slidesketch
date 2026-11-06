import SwiftUI
import Combine
import AVFoundation

// Serialize background saves so an older write can never overwrite a newer one.
final class DeckPersistence: @unchecked Sendable {
    nonisolated private let queue = DispatchQueue(label: "HandwrittenSlides.persistence", qos: .utility)
    nonisolated private let url: URL
    nonisolated init(url: URL) { self.url = url }
    nonisolated func save(_ deck: StudioDeck, completion: @escaping @Sendable (String?) -> Void) {
        queue.async { [self] in
            do { try JSONEncoder().encode(deck).write(to: url, options: .atomic); completion(nil) }
            catch { completion(error.localizedDescription) }
        }
    }
    nonisolated func flush(_ deck: StudioDeck) throws {
        try queue.sync { try JSONEncoder().encode(deck).write(to: url, options: .atomic) }
    }
}

// Geometry-only changes go straight to Core Animation. SwiftUI content, text
// layout and image decoding are reused throughout a drag.
struct TransformElementSurface: UIViewControllerRepresentable {
    var element: SlideElement
    @ObservedObject var store: DeckStore
    var animateImages: Bool
    func makeUIViewController(context: Context) -> TransformElementController {
        TransformElementController(element: element, store: store, animateImages: animateImages)
    }
    func updateUIViewController(_ controller: TransformElementController, context: Context) {
        controller.update(element: element, animateImages: animateImages)
    }
}

final class TransformElementController: UIViewController {
    private var original: SlideElement
    private let store: DeckStore
    private var animateImages: Bool
    private var videoID: UUID?
    private var videoPaused: Bool
    private let host: UIHostingController<SlideElementContent>
    private var subscription: AnyCancellable?
    private var contentElement: SlideElement
    private(set) var contentUpdates = 0
    init(element: SlideElement, store: DeckStore, animateImages: Bool) {
        original = element; contentElement = element; self.store = store; self.animateImages = animateImages
        videoID = store.editorVideoID; videoPaused = store.editorVideoPaused
        host = UIHostingController(rootView: SlideElementContent(element: element, store: store, animateImages: animateImages, allowsVideoPreview: animateImages))
        super.init(nibName: nil, bundle: nil)
        loadViewIfNeeded()
        subscription = store.transformPreview.$elements.sink { [weak self] values in
            guard let self else { return }; self.apply(values[self.original.id] ?? self.original)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func loadView() {
        view = UIView(); view.backgroundColor = .clear; view.isOpaque = false; view.isUserInteractionEnabled = false
        addChild(host); host.view.backgroundColor = .clear; host.view.isOpaque = false
        view.addSubview(host.view); host.didMove(toParent: self)
    }
    func update(element: SlideElement, animateImages: Bool) {
        let changed = original != element || self.animateImages != animateImages || videoID != store.editorVideoID || videoPaused != store.editorVideoPaused
        original = element; self.animateImages = animateImages; videoID = store.editorVideoID; videoPaused = store.editorVideoPaused
        if changed { setContent(element) }
        apply(store.transformPreview.elements[element.id] ?? element)
    }
    private func setContent(_ element: SlideElement) {
        contentElement = element; contentUpdates += 1
        host.rootView = SlideElementContent(element: element, store: store, animateImages: animateImages, allowsVideoPreview: animateImages)
    }
    private func apply(_ element: SlideElement) {
        // Text width needs reflow; moving/rotating it does not.
        if element.kind == .text && (contentElement.width != element.width || contentElement.fontSize != element.fontSize || contentElement.height != element.height) { setContent(element) }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        host.view.bounds = CGRect(x: 0, y: 0, width: contentElement.width, height: contentElement.height)
        host.view.center = element.center
        host.view.transform = CGAffineTransform(scaleX: element.width / max(0.001, contentElement.width), y: element.height / max(0.001, contentElement.height)).concatenating(CGAffineTransform(rotationAngle: element.rotation * .pi / 180))
        CATransaction.commit()
    }
}

// Erasers must participate in the enclosing SwiftUI blend group.
private struct MovingEraser: View {
    let element: SlideElement
    let store: DeckStore
    @ObservedObject var preview: CanvasTransformPreview
    var body: some View {
        let value = preview.elements[element.id] ?? element
        SlideElementContent(element: value, store: store)
            .rotationEffect(.degrees(value.rotation)).position(x: value.center.x, y: value.center.y)
    }
}

struct EditableObjectSurface: View {
    let element: SlideElement
    let store: DeckStore
    var animateImages: Bool
    var body: some View {
        if element.kind == .erase {
            MovingEraser(element: element, store: store, preview: store.transformPreview)
        } else {
            TransformElementSurface(element: element, store: store, animateImages: animateImages)
                .frame(width: store.canvasSize.width, height: store.canvasSize.height)
                .blendMode(element.kind == .fill && element.fillBehind == true ? .destinationOver : .normal)
                .allowsHitTesting(false)
        }
    }
}

struct SlidePreviewKey: Hashable {
    let value: Int
    init(slide: StudioSlide, canvasSize: CGSize = PresentationDimensions.standard.size) {
        var h = Hasher(); h.combine(slide.id); h.combine(slide.paper); h.combine(canvasSize.width); h.combine(canvasSize.height)
        for layer in slide.layers ?? [] { h.combine(layer.id); h.combine(layer.visible); h.combine(layer.opacity); h.combine(layer.blendMode.rawValue) }
        for e in slide.elements {
            h.combine(RasterDrawingKey([e])); h.combine(e.kind.rawValue); h.combine(e.layerID)
            h.combine(e.text); h.combine(e.font); h.combine(e.fontSize); h.combine(e.color); h.combine(e.name)
        }
        value = h.finalize()
    }
}

@MainActor
final class SlidePreviewCache {
    private let images = NSCache<NSNumber, UIImage>()
    init() { images.totalCostLimit = 8 * 1024 * 1024 }
    func image(_ key: SlidePreviewKey) -> UIImage? { images.object(forKey: NSNumber(value: key.value)) }
    func insert(_ image: UIImage, key: SlidePreviewKey) { images.setObject(image, forKey: NSNumber(value: key.value), cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)) }
}

struct PreviewLayer: @unchecked Sendable {
    let atoms: [RasterAtom]
    let opacity: Double
    let blend: CGBlendMode
}

extension LayerBlendMode {
    var cgBlend: CGBlendMode { switch self {
        case .normal: .normal; case .multiply: .multiply; case .darken: .darken; case .colorBurn: .colorBurn
        case .screen: .screen; case .lighten: .lighten; case .colorDodge: .colorDodge
        case .overlay: .overlay; case .softLight: .softLight; case .hardLight: .hardLight
        case .difference: .difference; case .exclusion: .exclusion; case .hue: .hue
        case .saturation: .saturation; case .color: .color; case .luminosity: .luminosity
    } }
}

@MainActor
enum SlidePreviewRenderer {
    static func layers(_ slide: StudioSlide, store: DeckStore) -> [PreviewLayer] {
        (slide.layers ?? []).filter(\.visible).map { layer in
            let atoms = slide.elements.filter { $0.layerID == layer.id }.compactMap { element -> RasterAtom? in
                if element.kind != .text && element.kind != .video { return DrawingRasterizer.atoms([element], store: store).first }
                let image: CGImage?
                if element.kind == .video, let asset = element.asset, let url = store.assetURL(asset) { image = AssetCache.shared.cachedPoster(url)?.cgImage }
                else { image = store.fillCache.preview(for: element, store: store) }
                guard let image else { return nil }
                return RasterAtom(image: image, rect: CGRect(x: element.x, y: element.y, width: element.width, height: element.height), rotation: element.rotation, flipX: element.flipX == true, flipY: element.flipY == true, mode: .normal)
            }
            return PreviewLayer(atoms: atoms, opacity: layer.opacity, blend: layer.blendMode.cgBlend)
        }
    }
    nonisolated static func render(_ layers: [PreviewLayer], paper: String, width: Int = 212, canvasSize: CGSize = PresentationDimensions.standard.size) -> CGImage? {
        let width = max(1, min(width, Int(Double(width) * canvasSize.width / canvasSize.height)))
        let height = max(1, Int(Double(width) * canvasSize.height / canvasSize.width))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rgb = UInt32(paper, radix: 16) ?? 0xFFFFFF
        context.setFillColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height); context.fill(bounds)
        for layer in layers {
            guard let image = DrawingRasterizer.render(layer.atoms, size: bounds.size, canvasSize: canvasSize) else { continue }
            context.saveGState(); context.setAlpha(layer.opacity); context.setBlendMode(layer.blend); context.draw(image, in: bounds); context.restoreGState()
        }
        return context.makeImage()
    }
}

struct SlideThumbnail: View, Equatable {
    let slide: StudioSlide
    let store: DeckStore
    private let key: SlidePreviewKey
    @State private var image: UIImage?
    init(slide: StudioSlide, store: DeckStore) {
        self.slide = slide; self.store = store; key = SlidePreviewKey(slide: slide, canvasSize: store.canvasSize)
        _image = State(initialValue: store.previewCache.image(key))
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.key == rhs.key && lhs.store === rhs.store }
    var body: some View {
        ZStack {
            Color(hex: slide.paper).aspectRatio(store.canvasSize.width / store.canvasSize.height, contentMode: .fit)
            if let image { Image(uiImage: image).resizable().scaledToFit() }
        }.frame(width: 106, height: 59.625)
            .task(id: key) {
                if let cached = store.previewCache.image(key) { image = cached; return }
                // Coalesce rapid edits and keep thumbnail work out of the input frame.
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                for element in slide.elements where element.kind == .video {
                    guard let asset = element.asset, let url = store.assetURL(asset), AssetCache.shared.cachedPoster(url) == nil else { continue }
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url)); generator.appliesPreferredTrackTransform = true; generator.maximumSize = CGSize(width: 424, height: 240)
                    if let frame = try? await generator.image(at: .zero) { AssetCache.shared.cachePoster(UIImage(cgImage: frame.image), at: url) }
                    guard !Task.isCancelled else { return }
                }
                let layers = SlidePreviewRenderer.layers(slide, store: store), paper = slide.paper, canvasSize = store.canvasSize
                let bitmap = await Task.detached(priority: .utility) { SlidePreviewRenderer.render(layers, paper: paper, canvasSize: canvasSize) }.value
                guard !Task.isCancelled, let bitmap else { return }
                let result = UIImage(cgImage: bitmap); store.previewCache.insert(result, key: key); image = result
            }
    }
}
