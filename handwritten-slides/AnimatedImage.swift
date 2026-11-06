import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// Keep animated files intact; converting them through UIImage.pngData() loses every frame but the first.
struct ImportedImage {
    let data: Data
    let fileExtension: String
    let size: CGSize

    init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        size = image.size
        if CGImageSourceGetType(source) as String? == UTType.gif.identifier {
            self.data = data; fileExtension = "gif"
        } else {
            guard let png = image.pngData() else { return nil }
            self.data = png; fileExtension = "png"
        }
    }
}

@MainActor
final class GIFAnimation {
    private let source: CGImageSource
    private let key: String
    let frameEndTimes: [TimeInterval]
    var duration: TimeInterval { frameEndTimes.last ?? 0 }
    var frameCount: Int { frameEndTimes.count }
    // Share a bounded frame cache across all GIFs, instead of decoding the entire animation into RAM.
    private static let frames: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 64
        return cache
    }()

    init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == UTType.gif.identifier,
              CGImageSourceGetCount(source) > 1 else { return nil }
        self.source = source; key = url.path
        var ends: [TimeInterval] = [], elapsed: TimeInterval = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? NSNumber)?.doubleValue
                ?? (gif?[kCGImagePropertyGIFDelayTime] as? NSNumber)?.doubleValue ?? 0.1
            elapsed += delay.isFinite && delay >= 0.011 ? delay : 0.1
            ends.append(elapsed)
        }
        frameEndTimes = ends
    }

    func frameIndex(at elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite, duration > 0 else { return 0 }
        let time = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        var low = 0, high = frameCount - 1
        while low < high {
            let middle = (low + high) / 2
            if time < frameEndTimes[middle] { high = middle } else { low = middle + 1 }
        }
        return low
    }

    func frame(at index: Int) -> UIImage? {
        guard frameEndTimes.indices.contains(index) else { return nil }
        let cacheKey = "\(key)#\(index)" as NSString
        if let image = Self.frames.object(forKey: cacheKey) { return image }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                      kCGImageSourceCreateThumbnailWithTransform: true,
                                      kCGImageSourceThumbnailMaxPixelSize: 1600,
                                      kCGImageSourceShouldCacheImmediately: true]
        guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: frame)
        Self.frames.setObject(image, forKey: cacheKey, cost: frame.bytesPerRow * frame.height)
        return image
    }
}

struct AnimatedGIFView: View {
    let animation: GIFAnimation
    @Environment(\.scenePhase) private var scenePhase
    @State private var started = Date()

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: scenePhase != .active)) { timeline in
            if let frame = animation.frame(at: animation.frameIndex(at: timeline.date.timeIntervalSince(started))) {
                Image(uiImage: frame).resizable()
            }
        }
        .onAppear { started = Date() }
        .accessibilityLabel("Animated GIF")
    }
}
