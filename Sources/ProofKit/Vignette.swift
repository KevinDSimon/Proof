import CoreImage

/// The Vignette card's values, in Lightroom's post-crop vignetting units.
public struct VignetteAdjustments: Codable, Equatable, Sendable {
    /// Darkens (negative) or lightens (positive) the edges.
    public var amount: Double = 0
    /// How far from the center the effect reaches its middle: 0 close to the center, 100 near the corners.
    public var midpoint: Double = 50
    /// -100 follows the frame's corners, 0 is an oval matching the frame, 100 is a circle.
    public var roundness: Double = 0
    /// How gradually the effect fades in: 0 is a hard edge.
    public var feather: Double = 50

    public static let amountRange = -100.0...100.0
    public static let midpointRange = 0.0...100.0
    public static let roundnessRange = -100.0...100.0
    public static let featherRange = 0.0...100.0

    private enum CodingKeys: String, CodingKey {
        case amount, midpoint, roundness, feather
    }

    public init(amount: Double = 0, midpoint: Double = 50, roundness: Double = 0, feather: Double = 50) {
        self.amount = amount
        self.midpoint = midpoint
        self.roundness = roundness
        self.feather = feather
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = VignetteAdjustments()
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? defaults.amount
        midpoint = try c.decodeIfPresent(Double.self, forKey: .midpoint) ?? defaults.midpoint
        roundness = try c.decodeIfPresent(Double.self, forKey: .roundness) ?? defaults.roundness
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? defaults.feather
    }

    public var isNeutral: Bool { self == VignetteAdjustments() }
}

/// Darkens or lightens the edges of the finished, cropped frame, as Lightroom's post-crop
/// vignetting does with its Highlight Priority style. See docs/decisions/0021-vignette.md.
enum Vignette {
    /// Stops at the frame's edge with Amount at -100 or +100, where the effect is full.
    static let stops: Float = 3

    /// Applies `vignette` to `image`, which is in linear light and is the whole cropped frame, so
    /// the effect centers on it. Values outside their ranges, which only a hand-edited sidecar can
    /// hold, are clamped. With Amount at 0 the image is returned as is.
    static func apply(_ vignette: VignetteAdjustments, to image: CIImage) -> CIImage {
        let amount = clamped(vignette.amount, to: VignetteAdjustments.amountRange)
        guard amount != 0, let kernel else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return image }
        let midpoint = clamped(vignette.midpoint, to: VignetteAdjustments.midpointRange) / 100
        let roundness = clamped(vignette.roundness, to: VignetteAdjustments.roundnessRange) / 100
        let feather = clamped(vignette.feather, to: VignetteAdjustments.featherRange) / 100

        // Positive roundness draws the oval's axes together toward a circle of the same area.
        let half = CGSize(width: extent.width / 2, height: extent.height / 2)
        let circle = (half.width * half.height).squareRoot()
        let toward = max(roundness, 0)
        let axes = CIVector(x: half.width + (circle - half.width) * toward,
                            y: half.height + (circle - half.height) * toward)
        // Negative roundness squares the oval off toward the frame's corners.
        let exponent = 2 * pow(4, max(-roundness, 0))
        // Where the effect is half, in units of the oval, whose edge touches the frame's sides.
        let middle = 0.3 + midpoint
        // At least two pixels wide, so Feather at 0 still has a smooth edge.
        let width = max(feather * 1.2 * middle, 2 / min(axes.x, axes.y))
        return kernel.apply(extent: extent, arguments: [
            image, CIVector(x: extent.midX, y: extent.midY), axes, Float(exponent),
            Float(middle - width / 2), Float(middle + width / 2), Float(amount / 100) * stops,
        ]) ?? image
    }

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the card
    /// then has no effect rather than failing the whole render.
    private static let kernel: CIColorKernel? = {
        let compiled = try? CIKernel.kernels(withMetalString: source)
        return compiled?.first { $0.name == "proofVignette" } as? CIColorKernel
    }()

    /// `t` runs from 0 inside the oval to 1 outside it. Darkening scales the pixel like exposure,
    /// so colors keep their hue and highlights darken with everything else. Lightening scales
    /// shadows and midtones like exposure but eases each channel toward white, so highlights
    /// approach white instead of clipping, as Lightroom's lightening does.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofVignette(sample_t pixel, float2 center, float2 axes, float exponent,
                                            float inner, float outer, float stops, destination dest) {
            float2 p = abs(dest.coord() - center) / axes;
            float d = pow(pow(p.x, exponent) + pow(p.y, exponent), 1.0 / exponent);
            float t = smoothstep(inner, outer, d);
            float gain = exp2(stops * t);
            float3 rgb = pixel.rgb;
            if (stops < 0.0) {
                rgb *= gain;
            } else {
                // Values above 1 pass through, so the curve's end at white joins them smoothly.
                float3 x = clamp(rgb, 0.0, 1.0);
                rgb += gain * x / (1.0 + (gain - 1.0) * x) - x;
            }
            return float4(rgb, pixel.a);
        }
    }
    }
    """
}
