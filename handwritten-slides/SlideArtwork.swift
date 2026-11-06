import SwiftUI
import AVKit

struct SlideArtwork: View {
    var name: String
    var body: some View {
        Canvas { context, size in
            if name == "Flower" { flower(&context, size: size) }
            else if name == "Landscape" { landscape(&context, size: size) }
            else if name == "Underline" {
                var path = Path(); path.move(to: CGPoint(x: 0, y: size.height * 0.6))
                path.addCurve(to: CGPoint(x: size.width, y: size.height * 0.3), control1: CGPoint(x: size.width * 0.3, y: size.height * 0.15), control2: CGPoint(x: size.width * 0.7, y: size.height * 0.9))
                context.stroke(path, with: .color(Color(hex: "D98664").opacity(0.7)), style: StrokeStyle(lineWidth: 7, lineCap: .round))
            } else { sun(&context, size: size) }
        }
        .accessibilityHidden(true)
    }
    private func flower(_ ctx: inout GraphicsContext, size: CGSize) {
        ctx.scaleBy(x: size.width / 500, y: size.height / 620)
        var stem = Path(); stem.move(to: CGPoint(x: 242, y: 532)); stem.addQuadCurve(to: CGPoint(x: 251, y: 200), control: CGPoint(x: 281, y: 397))
        ctx.stroke(stem, with: .color(Color(hex: "45674C")), style: StrokeStyle(lineWidth: 8, lineCap: .round))
        var leaves = Path(); leaves.move(to: CGPoint(x: 260, y: 405)); leaves.addQuadCurve(to: CGPoint(x: 166, y: 302), control: CGPoint(x: 167, y: 384)); leaves.addQuadCurve(to: CGPoint(x: 260, y: 405), control: CGPoint(x: 259, y: 326))
        leaves.move(to: CGPoint(x: 262, y: 356)); leaves.addQuadCurve(to: CGPoint(x: 366, y: 261), control: CGPoint(x: 363, y: 340)); leaves.addQuadCurve(to: CGPoint(x: 262, y: 356), control: CGPoint(x: 283, y: 268))
        ctx.fill(leaves, with: .color(Color(hex: "78966B")))
        for i in 0..<7 {
            var petalContext = ctx
            petalContext.translateBy(x: 270, y: 181)
            petalContext.rotate(by: .degrees(Double(i) * 51.43 + 8))
            let petal = Path(ellipseIn: CGRect(x: -43, y: -158, width: 86, height: 175))
            petalContext.fill(petal, with: .color(Color(hex: "D98664")))
        }
        ctx.fill(Path(ellipseIn: CGRect(x: 218, y: 129, width: 104, height: 104)), with: .color(Color(hex: "EDC268")))
        var pot = Path(); pot.move(to: CGPoint(x: 187, y: 499)); pot.addQuadCurve(to: CGPoint(x: 333, y: 503), control: CGPoint(x: 259, y: 473)); pot.addLine(to: CGPoint(x: 309, y: 603)); pot.addLine(to: CGPoint(x: 215, y: 603)); pot.closeSubpath()
        ctx.fill(pot, with: .color(Color(hex: "E1CBAA")))
        for i in 0..<3 {
            var line = Path(); let y = CGFloat(527 + i * 25); line.move(to: CGPoint(x: 207 + i * 6, y: Int(y))); line.addQuadCurve(to: CGPoint(x: 316 - i * 6, y: Int(y) + 2), control: CGPoint(x: 260, y: Int(y) - 5))
            ctx.stroke(line, with: .color(Color(hex: "B5A080").opacity(0.6)), lineWidth: 2)
        }
        for i in 0..<450 {
            let x = CGFloat((i * 73) % 300 + 115), y = CGFloat((i * 47) % 280 + 30)
            ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.4, height: 1.4)), with: .color(.white.opacity(0.18)))
        }
    }
    private func landscape(_ ctx: inout GraphicsContext, size: CGSize) {
        ctx.scaleBy(x: size.width / 600, y: size.height / 420)
        ctx.clip(to: Path(roundedRect: CGRect(x: 0, y: 0, width: 600, height: 420), cornerRadius: 160))
        ctx.fill(Path(CGRect(x: 0, y: 0, width: 600, height: 420)), with: .color(Color(hex: "DBE4D4")))
        ctx.fill(Path(ellipseIn: CGRect(x: 357, y: 47, width: 114, height: 114)), with: .color(Color(hex: "E8C66E")))
        for (i, color) in ["93A780", "506D54", "D98969"].enumerated() {
            let y = CGFloat(260 + i * 70)
            var p = Path(); p.move(to: CGPoint(x: -20, y: y)); p.addCurve(to: CGPoint(x: 620, y: y - 30), control1: CGPoint(x: 180, y: y - 210), control2: CGPoint(x: 330, y: y + 180)); p.addLine(to: CGPoint(x: 620, y: 450)); p.addLine(to: CGPoint(x: -20, y: 450)); p.closeSubpath()
            ctx.fill(p, with: .color(Color(hex: color)))
        }
        var trail = Path(); trail.move(to: CGPoint(x: 160, y: 440)); trail.addQuadCurve(to: CGPoint(x: 345, y: 265), control: CGPoint(x: 393, y: 319))
        ctx.stroke(trail, with: .color(Color(hex: "F3E7C7")), lineWidth: 16)
    }
    private func sun(_ ctx: inout GraphicsContext, size: CGSize) {
        ctx.scaleBy(x: size.width / 260, y: size.height / 260)
        ctx.fill(Path(ellipseIn: CGRect(x: 72, y: 72, width: 116, height: 116)), with: .color(Color(hex: "E8BB62")))
        for i in 0..<16 {
            let angle = Double(i) * .pi / 8
            var p = Path(); p.move(to: CGPoint(x: 130 + cos(angle) * 87, y: 130 + sin(angle) * 87)); p.addLine(to: CGPoint(x: 130 + cos(angle + 0.015) * 111, y: 130 + sin(angle + 0.015) * 111))
            ctx.stroke(p, with: .color(Color(hex: "B2823C")), style: StrokeStyle(lineWidth: 3, lineCap: .round))
        }
    }
}

@MainActor
final class AssetCache {
    static let shared = AssetCache()
    private let images = NSCache<NSString, UIImage>()
    private let animations: NSCache<NSString, GIFAnimation> = {
        let cache = NSCache<NSString, GIFAnimation>(); cache.countLimit = 12; return cache
    }()
    func animation(_ url: URL) -> GIFAnimation? {
        guard url.pathExtension.lowercased() == "gif" else { return nil }
        if let cached = animations.object(forKey: url.path as NSString) { return cached }
        guard let animation = GIFAnimation(url: url) else { return nil }
        animations.setObject(animation, forKey: url.path as NSString)
        return animation
    }
    func cachedPoster(_ url: URL) -> UIImage? { images.object(forKey: ("poster:" + url.path) as NSString) }
    func cachePoster(_ image: UIImage, at url: URL) { images.setObject(image, forKey: ("poster:" + url.path) as NSString) }
    func image(_ url: URL) -> UIImage? {
        if let cached = images.object(forKey: url.path as NSString) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        images.setObject(image, forKey: url.path as NSString)
        return image
    }
}

struct VideoPoster: View {
    let url: URL
    @State private var image: UIImage?
    init(url: URL) { self.url = url; _image = State(initialValue: AssetCache.shared.cachedPoster(url)) }
    var body: some View {
        ZStack {
            Color(hex: "24483E")
            if let image { Image(uiImage: image).resizable() }
            Image(systemName: "play.circle.fill").font(.system(size: 75, weight: .ultraLight)).foregroundStyle(.white.opacity(0.9)).shadow(radius: 10)
        }
        .task(id: url) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 1000, height: 700)
            if let frame = try? await generator.image(at: .zero) {
                let thumbnail = UIImage(cgImage: frame.image); image = thumbnail; AssetCache.shared.cachePoster(thumbnail, at: url)
            }
        }
        .clipped()
    }
}

struct VideoSurface: UIViewControllerRepresentable {
    var player: AVPlayer?
    var showsControls = true
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.videoGravity = .resize; controller.player = player; controller.showsPlaybackControls = showsControls
        return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.showsPlaybackControls = showsControls
        if controller.player !== player { controller.player = player }
    }
}

struct InlineVideo: View {
    var url: URL
    var options = VideoOptions()
    var preview = false
    var playbackRequested: Bool? = nil
    var onFinished: (() -> Void)? = nil
    @State private var player: AVPlayer?
    var body: some View {
        VideoSurface(player: player, showsControls: playbackRequested == nil)
            .onAppear {
                let player = AVPlayer(url: url)
                player.defaultRate = Float(options.speed); player.isMuted = options.muted
                self.player = player
                if playbackRequested == true || (playbackRequested == nil && (options.autoplay || preview)) { resume(player) }
            }
            .onChange(of: options) {
                player?.defaultRate = Float(options.speed); player?.isMuted = options.muted
                if player?.rate != 0 { player?.rate = Float(options.speed) }
            }
            .onChange(of: playbackRequested) {
                if playbackRequested == true, let player { resume(player) }
                else if playbackRequested == false { player?.pause() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
                guard let player, let item = notification.object as? AVPlayerItem, item === player.currentItem else { return }
                guard options.loop else { onFinished?(); return }
                restart(player)
            }
            .onDisappear { player?.pause(); player = nil }
    }
    private func resume(_ player: AVPlayer) {
        let duration = player.currentItem?.duration.seconds ?? .nan
        if duration.isFinite && player.currentTime().seconds >= duration - 0.05 { restart(player) }
        else { player.playImmediately(atRate: Float(options.speed)) }
    }
    private func restart(_ player: AVPlayer) {
        player.seek(to: .zero) { finished in
            guard finished else { return }
            Task { @MainActor in
                guard self.player === player, playbackRequested != false else { return }
                player.playImmediately(atRate: Float(options.speed))
            }
        }
    }
}

struct SlideElementContent: View {
    var element: SlideElement
    var store: DeckStore
    var presenting = false
    var animateImages = false
    var allowsVideoPreview = false
    var body: some View {
        Group {
            switch element.kind {
            case .text:
                Text(element.text)
                    .font(.custom(element.font, size: element.fontSize))
                    .foregroundStyle(Color(hex: element.color))
                    .frame(width: element.width, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
            case .erase:
                if let mark = element.eraser {
                    EraserShape(mark: mark)
                        .frame(width: mark.bounds.width, height: mark.bounds.height)
                        .scaleEffect(x: element.width / mark.bounds.width, y: element.height / mark.bounds.height, anchor: .topLeading)
                        .frame(width: element.width, height: element.height, alignment: .topLeading)
                        .blendMode(.destinationOut)
                } else if let asset = element.asset, let url = store.assetURL(asset), let image = AssetCache.shared.image(url) {
                    Image(uiImage: image).resizable().blendMode(.destinationOut)
                }
            case .artwork: SlideArtwork(name: element.name)
            case .image, .ink, .fill:
                if let asset = element.asset, let url = store.assetURL(asset) {
                    if element.kind == .image, animateImages, let animation = AssetCache.shared.animation(url) {
                        AnimatedGIFView(animation: animation).id(asset)
                    } else if let image = AssetCache.shared.image(url) {
                        Image(uiImage: image).resizable()
                            .blendMode(element.kind == .fill && element.fillBehind == true ? .destinationOver : .normal)
                    }
                }
            case .video:
                if let asset = element.asset, let url = store.assetURL(asset) {
                    if presenting { InlineVideo(url: url, options: element.videoOptions ?? VideoOptions()) }
                    else if allowsVideoPreview && store.editorVideoID == element.id {
                        InlineVideo(url: url, options: element.videoOptions ?? VideoOptions(), playbackRequested: !store.editorVideoPaused) { store.editorVideoPaused = true }
                    } else { VideoPoster(url: url) }
                }
            }
        }
        .frame(width: element.width, height: element.height)
        .scaleEffect(x: element.flipX == true ? -1 : 1, y: element.flipY == true ? -1 : 1)
    }
}

struct StaticSlide: View {
    var slide: StudioSlide
    var store: DeckStore
    var presenting = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(hex: slide.paper)
            ForEach(slide.layers ?? []) { layer in
                if layer.visible {
                    LayerElements(slide: slide, layer: layer, store: store, presenting: presenting, animateImages: presenting)
                        .compositingGroup().opacity(layer.opacity).blendMode(layer.blendMode.blend)
                }
            }
        }
        .frame(width: store.canvasSize.width, height: store.canvasSize.height)
        .clipped()
    }
}
