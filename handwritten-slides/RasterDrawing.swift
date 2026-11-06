import SwiftUI
import Combine
import ImageIO

extension SlideElement {
    var isDrawingContent: Bool { kind == .ink || kind == .fill || kind == .erase || kind == .artwork }
}

struct RasterAtom: @unchecked Sendable {
    let image: CGImage
    let rect: CGRect
    let rotation: Double
    let flipX: Bool
    let flipY: Bool
    let mode: CGBlendMode
}

// One small immutable snapshot is handed to the worker; UIKit and the live deck stay on the main actor.
@MainActor
enum DrawingRasterizer {
    static func atoms(_ elements: [SlideElement], store: DeckStore, linework: Bool = false) -> [RasterAtom] {
        elements.compactMap { element in
            let image: CGImage?
            if let asset = linework ? (element.lineworkAsset ?? element.asset) : element.asset, let url = store.assetURL(asset) {
                image = AssetCache.shared.image(url)?.cgImage
            } else if element.kind == .erase || element.kind == .artwork {
                image = store.fillCache.preview(for: element, store: store)
            } else { image = nil }
            guard let image else { return nil }
            return RasterAtom(image: image, rect: CGRect(x: element.x, y: element.y, width: element.width, height: element.height), rotation: element.rotation, flipX: element.flipX == true, flipY: element.flipY == true, mode: element.kind == .erase ? .destinationOut : element.kind == .fill && element.fillBehind == true ? .destinationOver : .normal)
        }
    }
    nonisolated static func render(_ atoms: [RasterAtom], size: CGSize = PresentationDimensions.standard.size, base: CGImage? = nil, canvasSize: CGSize = PresentationDimensions.standard.size) -> CGImage? {
        guard let context = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: Int(size.width) * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(origin: .zero, size: size))
        if let base { context.draw(base, in: CGRect(origin: .zero, size: size)) }
        context.translateBy(x: 0, y: size.height); context.scaleBy(x: size.width / canvasSize.width, y: -size.height / canvasSize.height)
        for atom in atoms {
            context.saveGState()
            context.translateBy(x: atom.rect.midX, y: atom.rect.midY)
            context.rotate(by: atom.rotation * .pi / 180)
            context.scaleBy(x: atom.flipX ? -1 : 1, y: atom.flipY ? -1 : 1)
            context.setBlendMode(atom.mode)
            context.scaleBy(x: 1, y: -1)
            context.draw(atom.image, in: CGRect(x: -atom.rect.width / 2, y: -atom.rect.height / 2, width: atom.rect.width, height: atom.rect.height))
            context.restoreGState()
        }
        return context.makeImage()
    }
    nonisolated static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}

@MainActor
final class LineworkFillCache {
    var slideID: UUID?
    var layerID: UUID?
    var elements: [SlideElement] = []
    var pixels: FillPixels?
    private var previews: [UUID: (SlideElement, CGImage)] = [:]
    func preview(for element: SlideElement, store: DeckStore) -> CGImage? {
        if let cached = previews[element.id], cached.0 == element { return cached.1 }
        let preview: AnyView
        if element.kind == .erase, let mark = element.eraser {
            preview = AnyView(EraserShape(mark: mark).frame(width: mark.bounds.width, height: mark.bounds.height)
                .scaleEffect(x: element.width / mark.bounds.width, y: element.height / mark.bounds.height, anchor: .topLeading)
                .frame(width: element.width, height: element.height, alignment: .topLeading))
        } else { preview = AnyView(SlideElementContent(element: element, store: store)) }
        let renderer = ImageRenderer(content: preview.environment(\.colorScheme, .light))
        renderer.scale = 1; renderer.isOpaque = false
        guard let image = renderer.uiImage?.cgImage else { return nil }
        if previews.count > 128 { previews.removeAll() }
        previews[element.id] = (element, image); return image
    }
}

struct RasterDrawingKey: Hashable {
    let value: Int
    init(_ elements: [SlideElement], canvasSize: CGSize = PresentationDimensions.standard.size) {
        var hash = Hasher(); hash.combine(canvasSize.width); hash.combine(canvasSize.height)
        for e in elements {
            hash.combine(e.id); hash.combine(e.asset); hash.combine(e.x); hash.combine(e.y); hash.combine(e.width); hash.combine(e.height)
            hash.combine(e.rotation); hash.combine(e.flipX); hash.combine(e.flipY); hash.combine(e.fillBehind)
            // Eraser marks are immutable once committed; transforms are covered above.
        }
        value = hash.finalize()
    }
}

@MainActor
final class RasterImageCache {
    private let images = NSCache<NSNumber, UIImage>()
    init() { images.totalCostLimit = 48 * 1024 * 1024 }
    func image(_ key: RasterDrawingKey) -> UIImage? { images.object(forKey: NSNumber(value: key.value)) }
    func insert(_ image: UIImage, key: RasterDrawingKey) { images.setObject(image, forKey: NSNumber(value: key.value), cost: (image.cgImage?.bytesPerRow ?? 0) * (image.cgImage?.height ?? 0)) }
}

struct RasterDrawingView: View {
    var elements: [SlideElement]
    let store: DeckStore
    @State private var image: UIImage?
    @State private var renderedElements: [SlideElement] = []
    var body: some View {
        // Keep a concrete view alive before the first bitmap arrives. An empty
        // Group has no appearance lifecycle, so its task never starts rendering.
        ZStack {
            Color.clear
            if let image { Image(uiImage: image).resizable() }
        }
            .frame(width: store.canvasSize.width, height: store.canvasSize.height)
            .task(id: RasterDrawingKey(elements, canvasSize: store.canvasSize)) {
                let key = RasterDrawingKey(elements, canvasSize: store.canvasSize)
                if let cached = store.rasterCache.image(key) { image = cached; renderedElements = elements; return }
                let appendOnly = !renderedElements.isEmpty && elements.count > renderedElements.count && elements.starts(with: renderedElements)
                let base = appendOnly ? image?.cgImage : nil
                let added = base == nil ? elements : Array(elements.dropFirst(renderedElements.count))
                let atoms = DrawingRasterizer.atoms(added, store: store), canvasSize = store.canvasSize
                let rendered = await Task.detached(priority: .userInitiated) { DrawingRasterizer.render(atoms, size: canvasSize, base: base, canvasSize: canvasSize) }.value
                guard !Task.isCancelled, let rendered else { return }
                let result = UIImage(cgImage: rendered)
                store.rasterCache.insert(result, key: key); image = result; renderedElements = elements
            }
    }
}

struct DrawingRenderGroup: Identifiable {
    let id: UUID
    var elements: [SlideElement]
    var drawing: Bool
    static func groups(_ elements: [SlideElement], separating: Set<UUID> = []) -> [DrawingRenderGroup] {
        var result: [DrawingRenderGroup] = []
        for element in elements {
            let drawing = element.isDrawingContent && !separating.contains(element.id)
            if drawing, result.last?.drawing == true { result[result.count - 1].elements.append(element) }
            else { result.append(DrawingRenderGroup(id: element.id, elements: [element], drawing: drawing)) }
        }
        return result
    }
}
