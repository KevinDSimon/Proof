import CoreImage
import CoreImage.CIFilterBuiltins

/// One spot the Spot Removal tool covers, such as sensor dust: a circle filled from another
/// part of the photo. Positions are from 0 to 1 on each axis, from the top left, of the whole
/// photo after lens corrections and perspective and before the crop, so a spot stays on what
/// it covers when the crop changes. See docs/decisions/0039-spot-removal.md.
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

    public static let radiusRange = 0.001...0.1
    public static let featherRange = 0.0...100.0
    public static let opacityRange = 0.0...100.0
    public static let defaultRadius = 0.006
    public static let defaultFeather = 50.0
    public static let defaultOpacity = 100.0

    private enum CodingKeys: String, CodingKey {
        case mode, x, y, sourceX, sourceY, radius, feather, opacity
    }

    public init(mode: Mode = .heal, x: Double, y: Double, sourceX: Double, sourceY: Double,
                radius: Double = Spot.defaultRadius, feather: Double = Spot.defaultFeather,
                opacity: Double = Spot.defaultOpacity) {
        self.mode = mode
        self.x = x
        self.y = y
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.radius = radius
        self.feather = feather
        self.opacity = opacity
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
    }

    public var center: CGPoint {
        get { CGPoint(x: x, y: y) }
        set { x = newValue.x; y = newValue.y }
    }

    public var source: CGPoint {
        get { CGPoint(x: sourceX, y: sourceY) }
        set { sourceX = newValue.x; sourceY = newValue.y }
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
        let clampedImage = image.clampedToExtent()
        // The source moved onto the spot.
        var patch = clampedImage.transformed(by: CGAffineTransform(translationX: center.x - source.x,
                                                                   y: center.y - source.y))
        if spot.mode == .heal, let kernel = healKernel {
            // The color and brightness around the spot, and around the source, from the pixels
            // outside the circle only, so the dust itself doesn't count. Both are weighted by
            // the same ring, so their ratio needs no normalizing. Blurring by the radius carries
            // the surroundings smoothly into the middle of the circle.
            let ring = CIFilter.radialGradient()
            ring.center = center
            ring.radius0 = Float(radius)
            ring.radius1 = Float(radius + 1)
            ring.color0 = gray(0)
            ring.color1 = gray(1)
            guard let weight = ring.outputImage else { return image }
            let reach = radius * 4
            let area = CGRect(x: center.x - reach, y: center.y - reach, width: reach * 2, height: reach * 2)
            func surroundings(_ image: CIImage) -> CIImage {
                image.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: weight])
                    .cropped(to: area).clampedToExtent()
                    .applyingGaussianBlur(sigma: radius)
            }
            patch = kernel.apply(extent: area, arguments: [patch, surroundings(clampedImage), surroundings(patch)]) ?? patch
        }
        let edge = max(radius * feather, 1)
        let mask = CIFilter.radialGradient()
        mask.center = center
        mask.radius0 = Float(max(radius - edge, 0))
        mask.radius1 = Float(radius)
        mask.color0 = gray(opacity)
        mask.color1 = gray(0)
        guard let maskImage = mask.outputImage else { return image }
        let circle = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        return patch.cropped(to: circle)
            .applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: maskImage])
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
        guard width > 0, height > 0, luminance.count == width * height, region.width > 0, region.height > 0 else { return nil }
        // The radius in each axis's 0-to-1 units.
        let rx = aspect >= 1 ? radius : radius / aspect
        let ry = aspect >= 1 ? radius * aspect : radius
        func value(at point: CGPoint) -> Float? {
            let col = Int(((point.x - region.minX) / region.width * Double(width)).rounded(.down))
            let row = Int(((point.y - region.minY) / region.height * Double(height)).rounded(.down))
            guard (0..<width).contains(col), (0..<height).contains(row) else { return nil }
            return log(max(luminance[row * width + col], 1e-5))
        }
        // Samples on rings around a circle's center, at fractions of its radius.
        let angles = (0..<24).map { Double($0) / 24 * 2 * .pi }
        func samples(around c: CGPoint, at scales: [Double]) -> [Float]? {
            var values: [Float] = []
            for s in scales {
                for a in angles {
                    guard let v = value(at: CGPoint(x: c.x + cos(a) * rx * s, y: c.y + sin(a) * ry * s)) else { return nil }
                    values.append(v)
                }
            }
            return values
        }
        let ringScales = [1.2, 1.5]
        let insideScales = [0, 0.35, 0.7, 0.95]
        guard let target = samples(around: center, at: ringScales) else { return nil }
        let targetMean = target.reduce(0, +) / Float(target.count)

        var best: (point: CGPoint, score: Float)?
        for distance in [2.4, 3.4] {
            for a in (0..<16).map({ Double($0) / 16 * 2 * .pi }) {
                let candidate = CGPoint(x: center.x + cos(a) * rx * distance, y: center.y + sin(a) * ry * distance)
                // The whole circle on the photo.
                guard candidate.x - rx >= 0, candidate.x + rx <= 1, candidate.y - ry >= 0, candidate.y + ry <= 1,
                      let ring = samples(around: candidate, at: ringScales),
                      let inside = samples(around: candidate, at: insideScales)
                else { continue }
                let ringMean = ring.reduce(0, +) / Float(ring.count)
                let offset = mode == .heal ? ringMean - targetMean : 0
                let ringDifference = zip(ring, target).map { pow($0 - $1 - offset, 2) }.reduce(0, +) / Float(ring.count)
                let insideMean = inside.reduce(0, +) / Float(inside.count)
                let roughness = inside.map { pow($0 - insideMean, 2) }.reduce(0, +) / Float(inside.count)
                // Nearer is better when the rest is equal: the light and grain are more alike.
                let score = ringDifference + 2 * roughness + Float(distance) * 0.0005
                if best == nil || score < best!.score { best = (candidate, score) }
            }
        }
        return best?.point
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
