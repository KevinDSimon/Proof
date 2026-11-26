import CoreImage
import CoreImage.CIFilterBuiltins
import os

/// One spot the Spot Removal tool covers, such as sensor dust: a circle, or a painted stroke for
/// a hair or a wire, filled from another part of the photo. Positions are from 0 to 1 on each
/// axis, from the top left, of the whole photo after lens corrections and perspective and before
/// the crop, so a spot stays on what it covers when the crop changes. See
/// docs/decisions/0039-spot-removal.md and 0047-spot-strokes.md.
public struct Spot: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, CaseIterable, Sendable {
        /// Takes the source's texture and matches it to the color and brightness around the spot.
        case heal
        /// Copies the source as it is.
        case clone
    }

    public var mode: Mode
    public var x: Double
    public var y: Double
    public var sourceX: Double
    public var sourceY: Double
    /// The circle's radius as a fraction of the photo's long edge, so the spot is round and covers
    /// the same part of the photo at every render size.
    public var radius: Double
    /// How gradually the spot fades into the photo at its edge: 0 is a hard edge, 100 fades from the center.
    public var feather: Double
    /// 0 leaves the photo as it was; 100 covers the spot fully.
    public var opacity: Double
    /// A stroke's path, as x and y pairs in a flat list, as a brush stroke's is. Empty for a
    /// circle. A stroke covers everything within `radius` of its path, and takes from the path
    /// moved by the offset from the spot's position to its source's; its position is the
    /// stroke's first point.
    public var points: [Double]

    public static let radiusRange = 0.001...0.1
    public static let featherRange = 0.0...100.0
    public static let opacityRange = 0.0...100.0
    public static let defaultRadius = 0.006
    public static let defaultFeather = 50.0
    public static let defaultOpacity = 100.0

    private enum CodingKeys: String, CodingKey {
        case mode, x, y, sourceX, sourceY, radius, feather, opacity, points
    }

    public init(mode: Mode = .heal, x: Double, y: Double, sourceX: Double, sourceY: Double,
                radius: Double = Spot.defaultRadius, feather: Double = Spot.defaultFeather,
                opacity: Double = Spot.defaultOpacity, path: [CGPoint] = []) {
        self.mode = mode
        self.x = x
        self.y = y
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.radius = radius
        self.feather = feather
        self.opacity = opacity
        self.points = path.flatMap { [$0.x, $0.y] }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A mode this version doesn't know heals, the closer of the two to any other.
        mode = try c.decodeIfPresent(String.self, forKey: .mode).flatMap(Mode.init(rawValue:)) ?? .heal
        x = try c.decode(Double.self, forKey: .x)
        y = try c.decode(Double.self, forKey: .y)
        sourceX = try c.decode(Double.self, forKey: .sourceX)
        sourceY = try c.decode(Double.self, forKey: .sourceY)
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? Self.defaultRadius
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? Self.defaultFeather
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? Self.defaultOpacity
        // Spots saved before strokes are circles.
        points = try c.decodeIfPresent([Double].self, forKey: .points) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mode, forKey: .mode)
        try c.encode(x, forKey: .x)
        try c.encode(y, forKey: .y)
        try c.encode(sourceX, forKey: .sourceX)
        try c.encode(sourceY, forKey: .sourceY)
        try c.encode(radius, forKey: .radius)
        try c.encode(feather, forKey: .feather)
        try c.encode(opacity, forKey: .opacity)
        // Circles are written as they were before strokes.
        if !points.isEmpty { try c.encode(points, forKey: .points) }
    }

    /// The spot's position. Moving it moves a stroke's whole path with it.
    public var center: CGPoint {
        get { CGPoint(x: x, y: y) }
        set {
            let dx = newValue.x - x, dy = newValue.y - y
            x = newValue.x
            y = newValue.y
            guard !points.isEmpty, dx != 0 || dy != 0 else { return }
            for i in points.indices { points[i] += i % 2 == 0 ? dx : dy }
        }
    }

    public var path: [CGPoint] {
        stride(from: 0, to: points.count - 1, by: 2).map { CGPoint(x: points[$0], y: points[$0 + 1]) }
    }

    /// A stroke has a path of at least two points; anything else is a circle at the spot's position.
    public var isStroke: Bool { points.count >= 4 }

    public mutating func append(_ point: CGPoint) {
        points += [point.x, point.y]
    }

    public var source: CGPoint {
        get { CGPoint(x: sourceX, y: sourceY) }
        set { sourceX = newValue.x; sourceY = newValue.y }
    }
}

/// How far the Spot Removal tool's spots reach for a press: a pointer takes a spot only within
/// its outline, while a finger also takes a small one from within 22 points of its center or
/// path, for the 44-point targets of Apple's Human Interface Guidelines.
public enum SpotReach: Sendable {
    case pointer
    case touch

    /// From a spot's center or path, in points, however small the spot shows.
    public var minimum: Double {
        switch self {
        case .pointer: 0
        case .touch: 22
        }
    }

    /// Which target a press takes, given each one's distance from the press and its radius, in
    /// points, in the order they are tried: the first whose outline holds the press, or else the
    /// nearest within reach.
    public func target(distances: [Double], radii: [Double]) -> Int? {
        if let inside = distances.indices.first(where: { distances[$0] <= radii[$0] }) { return inside }
        return distances.indices.filter { distances[$0] <= minimum }.min { distances[$0] < distances[$1] }
    }
}

/// Fills each spot from its source, in order, so a later spot may take from an earlier one's
/// result. Runs on the whole uncropped photo in linear light, before halation and bloom, so
/// dust doesn't glow.
enum SpotRemoval {
    /// Applies `spots` to `image`, the whole photo after perspective. Values outside their ranges,
    /// which only a hand-edited sidecar can hold, are clamped.
    static func apply(_ spots: [Spot], to image: CIImage) -> CIImage {
        let extent = image.extent
        guard !spots.isEmpty, extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return image }
        return spots.reduce(image) { apply($1, to: $0, extent: extent) }
    }

    private static func apply(_ spot: Spot, to image: CIImage, extent: CGRect) -> CIImage {
        let opacity = clamped(spot.opacity, to: Spot.opacityRange) / 100
        guard opacity > 0 else { return image }
        let radius = max(clamped(spot.radius, to: Spot.radiusRange) * max(extent.width, extent.height), 0.5)
        let feather = clamped(spot.feather, to: Spot.featherRange) / 100
        // Core Image's y axis points up.
        func placed(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: extent.minX + x * extent.width, y: extent.maxY - y * extent.height)
        }
        let center = placed(spot.x, spot.y), source = placed(spot.sourceX, spot.sourceY)
        if spot.isStroke {
            // A stroke whose source is still on it, as while it is painted, changes nothing.
            guard center != source else { return image }
            let path = spot.path.map { placed($0.x, $0.y) }
            guard let stroke = StrokeRaster.images(of: path, radius: radius, feather: feather, extent: extent)
            else { return image }
            // A whole-pixel ring, as a circle's, so the stroke's own pixels don't count.
            let reach = radius * 4
            return fill(image, center: center, source: source, mode: spot.mode, radius: radius,
                        outside: stroke.outside, area: stroke.bounds.insetBy(dx: -reach, dy: -reach),
                        mask: stroke.mask.applyingFilter("CIColorMatrix", parameters: [
                            "inputRVector": CIVector(x: opacity, y: 0, z: 0, w: 0),
                            "inputGVector": CIVector(x: 0, y: opacity, z: 0, w: 0),
                            "inputBVector": CIVector(x: 0, y: 0, z: opacity, w: 0),
                        ]),
                        bounds: stroke.bounds, extent: extent)
        }
        // The color and brightness around the spot, and around the source, are taken from the
        // pixels outside the circle only, so the dust itself doesn't count.
        let ring = CIFilter.radialGradient()
        ring.center = center
        ring.radius0 = Float(radius)
        ring.radius1 = Float(radius + 1)
        ring.color0 = gray(0)
        ring.color1 = gray(1)
        guard let weight = ring.outputImage else { return image }
        let reach = radius * 4
        let area = CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)
        let edge = max(radius * feather, 1)
        let mask = CIFilter.radialGradient()
        mask.center = center
        mask.radius0 = Float(max(radius - edge, 0))
        mask.radius1 = Float(radius)
        mask.color0 = gray(opacity)
        mask.color1 = gray(0)
        guard let maskImage = mask.outputImage else { return image }
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        return fill(image, center: center, source: source, mode: spot.mode, radius: radius, outside: weight,
                    area: area, mask: maskImage, bounds: circle, extent: extent)
    }

    /// Moves the source onto the spot, heals it if asked, and blends it into `image` by `mask`
    /// within `bounds`. `outside` weighs the pixels around the spot that Heal matches to, and is
    /// 0 on the spot itself; `area` holds the spot and enough of its surroundings to blur.
    private static func fill(_ image: CIImage, center: CGPoint, source: CGPoint, mode: Spot.Mode, radius: Double,
                             outside weight: CIImage, area: CGRect, mask: CIImage, bounds: CGRect,
                             extent: CGRect) -> CIImage {
        let clampedImage = image.clampedToExtent()
        // The source moved onto the spot.
        var patch = clampedImage.transformed(by: CGAffineTransform(translationX: center.x - source.x,
                                                                   y: center.y - source.y))
        if mode == .heal, let kernel = healKernel {
            // Both surroundings are weighted the same, so their ratio needs no normalizing.
            // Blurring by the radius carries the surroundings smoothly into the middle of the spot.
            func surroundings(_ image: CIImage) -> CIImage {
                image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight])
                    .cropped(to: area).clampedToExtent()
                    .applyingGaussianBlur(sigma: radius)
            }
            patch = kernel.apply(extent: area, arguments: [patch, surroundings(clampedImage), surroundings(patch)]) ?? patch
        }
        return patch.cropped(to: bounds)
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            .cropped(to: extent)
    }

    /// In linear light, as the working space is, so a mask's value is the share it blends.
    private static func gray(_ value: Double) -> CIColor {
        CIColor(red: value, green: value, blue: value, colorSpace: linear) ?? CIColor(red: value, green: value, blue: value)
    }

    private static let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    // MARK: Choosing a source

    /// Where to take a spot at `center` from: the nearby circle whose surroundings look most like
    /// the spot's and whose inside is smoothest, so it holds no dust or detail of its own. For
    /// Heal only the texture is compared, since healing matches the brightness; for Clone, which
    /// copies as it is, the brightness counts too.
    /// `luminance` is a grid of `width` × `height` linear values, rows from the top, covering
    /// `region` of the photo, in the photo's 0-to-1 coordinates. `radius` is the spot's, in
    /// those coordinates of the long edge; `aspect` is the photo's width over its height.
    /// `nil` when no candidate fits on the photo.
    static func bestSource(center: CGPoint, radius: Double, mode: Spot.Mode = .heal, aspect: Double, luminance: [Float],
                           width: Int, height: Int, region: CGRect) -> CGPoint? {
        bestOffset(path: [center], radius: radius, mode: mode, aspect: aspect, luminance: luminance,
                   width: width, height: height, region: region)
            .map { CGPoint(x: center.x + $0.dx, y: center.y + $0.dy) }
    }

    /// How far to move a spot covering everything within `radius` of `path` to take it from the
    /// nearby area that fits best, as `bestSource` chooses for a circle, which is a path of one
    /// point. For a stroke the surroundings are sampled around the whole path, leaving out any
    /// sample on the stroke itself, and the candidates are the stroke moved two and a half to
    /// three and a half radii in 16 directions; moved along its own length it covers itself, so
    /// its roughness rules that out.
    static func bestOffset(path: [CGPoint], radius: Double, mode: Spot.Mode = .heal, aspect: Double, luminance: [Float],
                           width: Int, height: Int, region: CGRect) -> CGVector? {
        guard !path.isEmpty, width > 0, height > 0, luminance.count == width * height,
              region.width > 0, region.height > 0 else { return nil }
        // The radius in each axis's 0-to-1 units.
        let rx = aspect >= 1 ? radius : radius / aspect
        let ry = aspect >= 1 ? radius * aspect : radius
        func value(at point: CGPoint) -> Float? {
            let col = Int(((point.x - region.minX) / region.width * Double(width)).rounded(.down))
            let row = Int(((point.y - region.minY) / region.height * Double(height)).rounded(.down))
            guard (0..<width).contains(col), (0..<height).contains(row) else { return nil }
            return log(max(luminance[row * width + col], 1e-5))
        }
        let centers = resampled(path, spacing: 0.5, rx: rx, ry: ry)
        // Samples on rings around each point of the path, at fractions of the radius.
        let angles = (0..<24).map { Double($0) / 24 * 2 * .pi }
        // Each as a point of the path and the way from it, added in that order to a candidate's
        // point, as a circle's samples always were.
        func samples(at scales: [Double], offStroke: Bool) -> [(center: CGPoint, step: CGVector)] {
            var points: [(center: CGPoint, step: CGVector)] = []
            for c in centers {
                for s in scales {
                    for a in angles {
                        let step = CGVector(dx: cos(a) * rx * s, dy: sin(a) * ry * s)
                        let p = CGPoint(x: c.x + step.dx, y: c.y + step.dy)
                        // In radii, so an ellipse in 0-to-1 units is a circle on the photo.
                        if offStroke, centers.count > 1, centers.contains(where: {
                            pow(($0.x - p.x) / rx, 2) + pow(($0.y - p.y) / ry, 2) <= 1
                        }) { continue }
                        points.append((c, step))
                    }
                }
            }
            return points
        }
        func values(_ points: [(center: CGPoint, step: CGVector)], moved offset: CGVector) -> [Float]? {
            var values: [Float] = []
            values.reserveCapacity(points.count)
            for p in points {
                let c = CGPoint(x: p.center.x + offset.dx, y: p.center.y + offset.dy)
                guard let v = value(at: CGPoint(x: c.x + p.step.dx, y: c.y + p.step.dy)) else { return nil }
                values.append(v)
            }
            return values
        }
        let ringPoints = samples(at: [1.2, 1.5], offStroke: true)
        let insidePoints = samples(at: [0, 0.35, 0.7, 0.95], offStroke: false)
        guard !ringPoints.isEmpty, let target = values(ringPoints, moved: .zero) else { return nil }
        let targetMean = target.reduce(0, +) / Float(target.count)
        let minX = path.map(\.x).min()!, maxX = path.map(\.x).max()!
        let minY = path.map(\.y).min()!, maxY = path.map(\.y).max()!

        var best: (offset: CGVector, score: Float)?
        for distance in [2.4, 3.4] {
            for a in (0..<16).map({ Double($0) / 16 * 2 * .pi }) {
                let offset = CGVector(dx: cos(a) * rx * distance, dy: sin(a) * ry * distance)
                // The whole spot on the photo.
                guard minX + offset.dx - rx >= 0, maxX + offset.dx + rx <= 1,
                      minY + offset.dy - ry >= 0, maxY + offset.dy + ry <= 1,
                      let ring = values(ringPoints, moved: offset),
                      let inside = values(insidePoints, moved: offset)
                else { continue }
                let ringMean = ring.reduce(0, +) / Float(ring.count)
                let shift = mode == .heal ? ringMean - targetMean : 0
                let ringDifference = zip(ring, target).map { pow($0 - $1 - shift, 2) }.reduce(0, +) / Float(ring.count)
                let insideMean = inside.reduce(0, +) / Float(inside.count)
                let roughness = inside.map { pow($0 - insideMean, 2) }.reduce(0, +) / Float(inside.count)
                // Nearer is better when the rest is equal: the light and grain are more alike.
                let score = ringDifference + 2 * roughness + Float(distance) * 0.0005
                if best == nil || score < best!.score { best = (offset, score) }
            }
        }
        return best?.offset
    }

    /// Points along `path` at most `spacing` radii apart, and at most 48 of them, so a long
    /// stroke is sampled evenly however fast it was painted. A single point stays as it is.
    static func resampled(_ path: [CGPoint], spacing: Double, rx: Double, ry: Double) -> [CGPoint] {
        guard path.count > 1 else { return path }
        // Lengths in radii.
        func length(_ a: CGPoint, _ b: CGPoint) -> Double { hypot((b.x - a.x) / rx, (b.y - a.y) / ry) }
        let total = zip(path, path.dropFirst()).map(length).reduce(0, +)
        let step = max(spacing, total / 47)
        guard total > 0 else { return [path[0]] }
        var points = [path[0]]
        var travelled = 0.0, next = step
        for (a, b) in zip(path, path.dropFirst()) {
            let segment = length(a, b)
            while segment > 0, next <= travelled + segment {
                let t = (next - travelled) / segment
                points.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                next += step
            }
            travelled += segment
        }
        if let last = path.last, points.last != last { points.append(last) }
        return points
    }

    // MARK: Kernel

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where healing
    /// then copies as Clone does rather than failing the whole render.
    private static let healKernel: CIColorKernel? = {
        let compiled = try? CIKernel.kernels(withMetalString: source)
        return compiled?.first { $0.name == "proofHeal" } as? CIColorKernel
    }()

    /// Scales the moved source by how much brighter, per channel, the spot's surroundings are
    /// than the source's. A ratio rather than a difference, since light in linear values scales,
    /// and dust takes away a share of it. Limited so a black source can't blow up.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofHeal(sample_t patch, sample_t around, sample_t aroundSource) {
            float3 gain = clamp((max(around.rgb, 0.0) + 1e-4) / (max(aroundSource.rgb, 0.0) + 1e-4), 0.0, 16.0);
            return float4(patch.rgb * gain, patch.a);
        }
    }
    }
    """
}

/// A stroke spot's masks, drawn on the processor over the stroke's bounds at the render's
/// resolution, up to `maxSize` pixels on the long edge, so a thin hair keeps a crisp edge in
/// an export and a long wire across the photo stays a small image. The brush mask's raster
/// isn't used: it covers the whole photo at a fixed 2048 pixels, too coarse for a hair, and
/// fades on a different curve than a circle spot does. The last few are kept, since a render
/// repeats while a slider moves.
enum StrokeRaster {
    static let maxSize = 4096

    struct Images {
        /// Fades from 1 within the stroke to 0 at its edge, as a circle spot's mask does.
        var mask: CIImage
        /// 0 on the stroke and 1 a pixel beyond its edge, for the surroundings Heal matches to.
        var outside: CIImage
        /// The part of the photo the stroke and its edge cover.
        var bounds: CGRect
    }

    private struct Key: Hashable {
        var path: [Double]
        var radius: Double
        var feather: Double
        var extent: [Double]
    }

    private struct Entry {
        var key: Key
        var mask: CGImage
        var outside: CGImage
        var bounds: CGRect
    }

    private static let cache = OSAllocatedUnfairLock(initialState: [Entry]())

    /// `path` and `radius` are in the image's pixels, in Core Image's coordinates; `feather` is
    /// from 0 to 1. `nil` for a stroke wholly off the image.
    static func images(of path: [CGPoint], radius: Double, feather: Double, extent: CGRect) -> Images? {
        let key = Key(path: path.flatMap { [$0.x, $0.y] }, radius: radius, feather: feather,
                      extent: [extent.minX, extent.minY, extent.width, extent.height])
        let entry: Entry
        if let hit = cache.withLock({ $0.first { $0.key == key } }) {
            entry = hit
        } else {
            guard let drawn = draw(path, radius: radius, feather: feather, extent: extent, key: key) else { return nil }
            entry = drawn
            cache.withLock { entries in
                entries.insert(entry, at: 0)
                if entries.count > 8 { entries.removeLast() }
            }
        }
        func placed(_ image: CGImage) -> CIImage {
            CIImage(cgImage: image, options: [.colorSpace: NSNull()])
                .transformed(by: CGAffineTransform(scaleX: entry.bounds.width / CGFloat(image.width),
                                                   y: entry.bounds.height / CGFloat(image.height))
                    .concatenating(CGAffineTransform(translationX: entry.bounds.minX, y: entry.bounds.minY)))
                // Beyond the bounds the mask is 0 and everything is outside the stroke.
                .clampedToExtent()
        }
        return Images(mask: placed(entry.mask), outside: placed(entry.outside), bounds: entry.bounds)
    }

    private static func draw(_ path: [CGPoint], radius: Double, feather: Double, extent: CGRect, key: Key) -> Entry? {
        // A pixel beyond the edge, so the outside weight reaches 1 within the bounds.
        let margin = radius + 2
        guard let minX = path.map(\.x).min(), let maxX = path.map(\.x).max(),
              let minY = path.map(\.y).min(), let maxY = path.map(\.y).max() else { return nil }
        let wanted = CGRect(x: minX - margin, y: minY - margin, width: maxX - minX + margin * 2,
                            height: maxY - minY + margin * 2).intersection(extent)
        guard !wanted.isNull, wanted.width > 0, wanted.height > 0 else { return nil }
        let scale = min(1, Double(maxSize) / max(wanted.width, wanted.height))
        let width = max(Int((wanted.width * scale).rounded(.up)), 1)
        let height = max(Int((wanted.height * scale).rounded(.up)), 1)
        // Whole raster pixels, from the bottom left as Core Image places them.
        let bounds = CGRect(x: wanted.minX, y: wanted.minY, width: Double(width) / scale, height: Double(height) / scale)
        // In raster pixels, rows from the top.
        let points = path.map { CGPoint(x: ($0.x - bounds.minX) * scale, y: (bounds.maxY - $0.y) * scale) }
        let r = radius * scale
        // As a circle spot's: full within the radius less the feather, at least a pixel of fade.
        let edge = max(radius * feather, 1) * scale
        let pixel = scale
        let reach = r + pixel
        var distance = [Double](repeating: .infinity, count: width * height)
        let segments = points.count == 1 ? [(points[0], points[0])] : Array(zip(points, points.dropFirst()))
        for (a, b) in segments {
            let x0 = max(Int((min(a.x, b.x) - reach).rounded(.down)), 0)
            let x1 = min(Int((max(a.x, b.x) + reach).rounded(.up)), width - 1)
            let y0 = max(Int((min(a.y, b.y) - reach).rounded(.down)), 0)
            let y1 = min(Int((max(a.y, b.y) + reach).rounded(.up)), height - 1)
            guard x0 <= x1, y0 <= y1 else { continue }
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            for y in y0...y1 {
                let py = Double(y) + 0.5
                for x in x0...x1 {
                    let px = Double(x) + 0.5
                    var t = lengthSquared > 0 ? ((px - a.x) * dx + (py - a.y) * dy) / lengthSquared : 0
                    t = min(max(t, 0), 1)
                    let d = hypot(px - (a.x + t * dx), py - (a.y + t * dy))
                    let i = y * width + x
                    if d < distance[i] { distance[i] = d }
                }
            }
        }
        var mask = [UInt8](repeating: 0, count: width * height)
        var outside = [UInt8](repeating: 255, count: width * height)
        for i in distance.indices where distance[i] < reach {
            let d = distance[i]
            mask[i] = byte((r - d) / edge)
            outside[i] = byte((d - r) / pixel)
        }
        guard let maskImage = grayImage(mask, width: width, height: height),
              let outsideImage = grayImage(outside, width: width, height: height) else { return nil }
        return Entry(key: key, mask: maskImage, outside: outsideImage, bounds: bounds)
    }

    private static func byte(_ weight: Double) -> UInt8 {
        UInt8((min(max(weight, 0), 1) * 255).rounded())
    }

    private static func grayImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
