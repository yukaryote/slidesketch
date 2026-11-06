import UIKit

extension StudioBrush {
    var usesGraphiteRenderer: Bool { self == .graphite || self == .pencil }
}

// The paper grain lives in canvas pixels, independently of the contact patch size.
// Tilting changes the patch, edge gradation and which paper valleys receive graphite.
struct GraphiteContact {
    var point: CGPoint
    var size: CGSize
    var angle: Double
    var opacity: Double
    var shading: Double
    var textureAngle: Double
    var gradation: Double

    init(point: CGPoint, width: Double, pressure: Double, altitude: Double, azimuth: Double, opacity: Double = 1, tiltSize: Double = 0.66, pressureSize: Double = 0.78, pressureOpacity: Double = 0.7, tiltOpacity: Double = 0.2, gradation: Double = 1, compression: Double = 1) {
        let pressure = min(1, max(0, pressure))
        let tilt = min(1, max(0, (.pi / 3 - altitude) / (.pi / 6)))
        shading = tilt * tilt * (3 - 2 * tilt)
        let base = max(0.7, width * max(0.02, 1 - pressureSize + pressureSize * pressure))
        size = CGSize(width: base * (1 + 6 * tiltSize / 0.66 * shading), height: base * (1 + (1.2 + 4.8 * (1 - min(1, max(0, compression)))) * tiltSize / 0.66 * shading))
        self.gradation = min(1, max(0, gradation))
        self.point = point; angle = azimuth; textureAngle = azimuth
        self.opacity = min(1, max(0, opacity)) * (1 - pressureOpacity + pressureOpacity * pressure) * (1 - tiltOpacity * shading)
    }

    func interpolated(to next: Self, fraction t: Double) -> Self {
        var result = self
        result.point = CGPoint(x: point.x + (next.point.x - point.x) * t, y: point.y + (next.point.y - point.y) * t)
        result.size = CGSize(width: size.width + (next.size.width - size.width) * t, height: size.height + (next.size.height - size.height) * t)
        let turn = atan2(sin(next.angle - angle), cos(next.angle - angle))
        result.angle = angle + turn * t
        result.textureAngle += atan2(sin(next.textureAngle - textureAngle), cos(next.textureAngle - textureAngle)) * t
        result.opacity += (next.opacity - opacity) * t
        result.shading += (next.shading - shading) * t
        return result
    }
}

// Mouse/finger have no pressure sensor. Smooth velocity supplies natural width
// changes without replacing Pencil force, tilt or the user's pressure curve.
struct FingerPencilDynamics {
    private var previous: (CGPoint, TimeInterval)?
    private var force = 0.85
    mutating func sample(_ point: CGPoint, time: TimeInterval) -> Double {
        defer { previous = (point, time) }
        guard let (last, timestamp) = previous, time > timestamp else { return force }
        let dt = max(1.0 / 240, time - timestamp)
        let speed = hypot(point.x - last.x, point.y - last.y) / dt
        let target = 0.35 + 0.65 / (1 + speed / 1400)
        force += (target - force) * (1 - exp(-dt / 0.025))
        return force
    }
}

final class GraphiteStrokeRaster {
    let canvasWidth: Int
    let canvasHeight: Int
    let brush: StudioBrush
    private let color: (UInt8, UInt8, UInt8)
    private let grainOffset: Int
    private let grainDepth: Double?
    private static let paper = makeTexture(directional: false)
    private static let streaks = makeTexture(directional: true)

    static func prepareTexture() { _ = paper; _ = streaks }

    // Correlated paper fibers and graphite streaks replace independent pixel noise.
    // Periodic interpolation keeps both fields seamless while preserving fine tooth.
    private static func makeTexture(directional: Bool) -> [UInt8] {
        func hash(_ x: Int, _ y: Int, _ seed: UInt32) -> Double {
            var value = UInt32(truncatingIfNeeded: x) &* 374761393 &+ UInt32(truncatingIfNeeded: y) &* 668265263 &+ seed
            value = (value ^ (value >> 13)) &* 1274126177; value ^= value >> 16
            return Double(value & 65535) / 65535
        }
        func noise(_ x: Double, _ y: Double, cellsX: Int, cellsY: Int, seed: UInt32) -> Double {
            let x = x * Double(cellsX) / 256, y = y * Double(cellsY) / 256
            let ix = Int(floor(x)), iy = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
            let tx = fx * fx * (3 - 2 * fx), ty = fy * fy * (3 - 2 * fy)
            let a = hash(ix % cellsX, iy % cellsY, seed), b = hash((ix+1) % cellsX, iy % cellsY, seed)
            let c = hash(ix % cellsX, (iy+1) % cellsY, seed), d = hash((ix+1) % cellsX, (iy+1) % cellsY, seed)
            return (a + (b-a)*tx) * (1-ty) + (c + (d-c)*tx) * ty
        }
        return (0..<(256*256)).map { index in
            let x = Double(index & 255), y = Double(index >> 8)
            let value: Double
            if directional {
                value = 0.75 * noise(x,y,cellsX:8,cellsY:128,seed:9341) + 0.25 * noise(x,y,cellsX:32,cellsY:256,seed:573)
            } else {
                value = 0.22 * noise(x,y,cellsX:16,cellsY:16,seed:42)
                    + 0.38 * noise(x,y,cellsX:64,cellsY:128,seed:179)
                    + 0.40 * noise(x,y,cellsX:128,cellsY:128,seed:613)
            }
            return UInt8(min(255, max(0, value * 255)))
        }
    }

    private static func streak(atX x: Double, y: Double) -> Double {
        let ix = Int(floor(x)), iy = Int(floor(y)), fx = x-floor(x), fy = y-floor(y)
        let a = Double(streaks[((iy & 255)<<8) | (ix & 255)])
        let b = Double(streaks[((iy & 255)<<8) | ((ix+1) & 255)])
        let c = Double(streaks[(((iy+1) & 255)<<8) | (ix & 255)])
        let d = Double(streaks[(((iy+1) & 255)<<8) | ((ix+1) & 255)])
        return ((a+(b-a)*fx)*(1-fy)+(c+(d-c)*fx)*fy)/255
    }
    private var pixels: [UInt8]
    private var previous: GraphiteContact?
    private var distanceToNext = 0.0
    private(set) var touchedBounds = CGRect.null
    private(set) var lastDamage = CGRect.null

    init(brush: StudioBrush, color: String, seed: UInt32 = 42, size: CGSize = PresentationDimensions.standard.size, grainDepth: Double? = nil) {
        self.brush = brush; self.grainDepth = grainDepth
        canvasWidth = max(1, min(4000, Int(size.width))); canvasHeight = max(1, min(4000, Int(size.height)))
        let rgb = UInt32(color, radix: 16) ?? 0x24483E
        self.color = (UInt8((rgb >> 16) & 255), UInt8((rgb >> 8) & 255), UInt8(rgb & 255))
        pixels = [UInt8](repeating: 0, count: canvasWidth * canvasHeight * 4)
        grainOffset = Int(seed & 255)
        Self.prepareTexture()
    }

    func add(_ input: GraphiteContact) {
        var contact = input
        guard contact.point.x.isFinite, contact.point.y.isFinite, contact.size.width.isFinite, contact.size.height.isFinite, contact.angle.isFinite, contact.opacity.isFinite else { return }
        lastDamage = .null
        let spacing = max(0.5, min(4, min(contact.size.width, contact.size.height) * 0.12))
        if let previous {
            let distance = hypot(contact.point.x - previous.point.x, contact.point.y - previous.point.y)
            if distance > 0 {
                contact.textureAngle = atan2(contact.point.y - previous.point.y, contact.point.x - previous.point.x)
                var traveled = distanceToNext
                while traveled <= distance {
                    stamp(previous.interpolated(to: contact, fraction: traveled / distance))
                    traveled += spacing
                }
                distanceToNext = traveled - distance
            } else if contact.size != previous.size || contact.opacity != previous.opacity || contact.shading != previous.shading || contact.angle != previous.angle {
                stamp(contact)
            }
        } else { stamp(contact); distanceToNext = spacing }
        previous = contact
    }

    func finish() { if let previous { lastDamage = .null; stamp(previous) } }

    private func stamp(_ contact: GraphiteContact) {
        let rx = max(0.35, Double(contact.size.width) / 2), ry = max(0.35, Double(contact.size.height) / 2)
        let cosine = cos(contact.angle), sine = sin(contact.angle)
        let extentX = abs(rx * cosine) + abs(ry * sine) + 1, extentY = abs(rx * sine) + abs(ry * cosine) + 1
        let bounds = CGRect(x: contact.point.x - extentX, y: contact.point.y - extentY, width: extentX * 2, height: extentY * 2).integral.intersection(CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
        guard !bounds.isNull, !bounds.isEmpty else { return }
        touchedBounds = touchedBounds.union(bounds); lastDamage = lastDamage.union(bounds)
        let tiny = min(rx, ry) < 2
        let outer = tiny ? pow(1 + 0.5 / min(rx, ry), 2) : 1
        let textureWeight = min(1, min(rx, ry) / 2)
        let strokeCosine = cos(contact.textureAngle), strokeSine = sin(contact.textureAngle)
        let paperDepth = (grainDepth ?? (brush == .pencil ? 0.98 : 0.9)) - 0.12 * contact.shading
        for y in Int(bounds.minY)..<Int(bounds.maxY) {
            let dy = Double(y) + 0.5 - Double(contact.point.y)
            for x in Int(bounds.minX)..<Int(bounds.maxX) {
                let dx = Double(x) + 0.5 - Double(contact.point.x)
                let u = (dx * cosine + dy * sine) / rx, v = (-dx * sine + dy * cosine) / ry
                let radius = u * u + v * v
                // Subpixel coverage prevents a light, one-pixel pencil point
                // disappearing between pixel centers.
                guard radius < outer else { continue }
                let q = max(0, 1-radius)
                let pointed = brush == .pencil ? 1-radius*radius : sqrt(q)
                let shaded = q*q
                let edge = tiny ? min(1, max(0, 0.5 + (1-sqrt(radius))*min(rx,ry))) : pointed*(1-contact.shading*contact.gradation)+shaded*contact.shading*contact.gradation
                let tooth = Double(Self.paper[((y & 255)<<8) | ((x+grainOffset) & 255)])/255
                let lay = Self.streak(atX: Double(x)*strokeCosine+Double(y)*strokeSine, y: -Double(x)*strokeSine+Double(y)*strokeCosine)
                let deposit = min(1, max(0, (paperDepth-tooth)/0.55)) * (0.48+0.52*lay)
                let graphite = 1-textureWeight+textureWeight*deposit
                let gradation = 1 - contact.shading * contact.gradation * 0.30 * (u + 1) / 2
                let alpha = UInt8(min(255, max(0, (edge * graphite * gradation * contact.opacity * 255).rounded())))
                let i = (y * canvasWidth + x) * 4
                // A stroke does not grow darker merely because it received more touch
                // samples. Successive strokes still build up through normal blending.
                guard alpha > pixels[i + 3] else { continue }
                pixels[i] = UInt8(Int(color.0) * Int(alpha) / 255)
                pixels[i + 1] = UInt8(Int(color.1) * Int(alpha) / 255)
                pixels[i + 2] = UInt8(Int(color.2) * Int(alpha) / 255)
                pixels[i + 3] = alpha
            }
        }
    }

    func snapshot() -> (CGImage, CGRect)? {
        guard !touchedBounds.isNull, !touchedBounds.isEmpty else { return nil }
        let bounds = touchedBounds.integral, width = Int(bounds.width), height = Int(bounds.height)
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { output in
            pixels.withUnsafeBytes { source in
                for row in 0..<height {
                    let offset = ((Int(bounds.minY) + row) * canvasWidth + Int(bounds.minX)) * 4
                    output.baseAddress!.advanced(by: row * width * 4).copyMemory(from: source.baseAddress!.advanced(by: offset), byteCount: width * 4)
                }
            }
        }
        guard let provider = CGDataProvider(data: data as CFData), let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return (image, bounds)
    }
}

final class GraphiteStrokeView: UIView {
    var raster: GraphiteStrokeRaster?
    func begin(brush: StudioBrush, color: String, canvasSize: CGSize = PresentationDimensions.standard.size) {
        raster = GraphiteStrokeRaster(brush: brush, color: color, size: canvasSize); isHidden = false
    }
    func add(_ contact: GraphiteContact) {
        raster?.add(contact)
        if let rect = raster?.lastDamage, !rect.isNull { setNeedsDisplay(rect) }
    }
    override func draw(_ rect: CGRect) {
        guard let (image, bounds) = raster?.snapshot(), let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState(); context.translateBy(x: bounds.minX, y: bounds.maxY); context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(origin: .zero, size: bounds.size)); context.restoreGState()
    }
    func clear() { raster = nil; isHidden = true; setNeedsDisplay() }
}
