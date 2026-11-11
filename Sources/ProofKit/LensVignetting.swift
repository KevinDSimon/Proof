import CoreImage

/// Manual lens vignetting, in Lightroom's units: it brightens (positive) or darkens (negative) the
/// corners about the center of the uncropped photo, to undo the lens's own falloff. Unlike the
/// Vignette card, which is an effect on the cropped frame, it is round, as a lens's falloff is,
/// and runs before every tone adjustment. See docs/decisions/0024-manual-lens-corrections.md.
public struct LensVignetting: Codable, Equatable, Sendable {
    /// Brightens (positive) or darkens (negative) the corners.
    public var amount: Double = 0
    /// How far from the center the correction reaches: 0 well toward the center, 100 only the corners.
    public var midpoint: Double = 50

    public static let amountRange = -100.0...100.0
    public static let midpointRange = 0.0...100.0

    /// Stops at the corners with Amount at 100.
    static let stops = 2.0

    private enum CodingKeys: String, CodingKey { case amount, midpoint }

    public init(amount: Double = 0, midpoint: Double = 50) {
        self.amount = amount
        self.midpoint = midpoint
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? 0
        midpoint = try c.decodeIfPresent(Double.self, forKey: .midpoint) ?? 50
    }

    /// The falloff's exponent: the correction in stops grows as the distance from the center,
    /// in units of the half diagonal, to this power. At the default midpoint it is about 2.5,
    /// close to a lens's natural falloff.
    static func exponent(midpoint: Double) -> Double {
        exp2(2.6 * min(max(midpoint, midpointRange.lowerBound), midpointRange.upperBound) / 100)
    }

    /// The correction in stops at `distance` from the center, in units of the half diagonal.
    func stops(at distance: Double) -> Double {
        let amount = min(max(amount, Self.amountRange.lowerBound), Self.amountRange.upperBound)
        return amount / 100 * Self.stops * pow(min(max(distance, 0), 1), Self.exponent(midpoint: midpoint))
    }

    /// Applies `vignetting` to `image`, the whole uncropped photo in linear light. Scales each
    /// pixel like exposure, so colors keep their hue, and in floating point, so it can't band.
    /// Returns the image as is with Amount at 0 or `nil`.
    static func apply(_ vignetting: LensVignetting?, to image: CIImage) -> CIImage {
        guard let vignetting, vignetting.amount != 0, let kernel else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return image }
        let amount = min(max(vignetting.amount, amountRange.lowerBound), amountRange.upperBound)
        let radius = (extent.width * extent.width + extent.height * extent.height).squareRoot() / 2
        return kernel.apply(extent: extent, arguments: [
            image, CIVector(x: extent.midX, y: extent.midY), Float(radius),
            Float(exponent(midpoint: vignetting.midpoint)), Float(amount / 100 * stops),
        ]) ?? image
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the
    /// correction then has no effect rather than failing the whole render.
    private static let kernel: CIColorKernel? = {
        let compiled = try? CIKernel.kernels(withMetalString: source)
        return compiled?.first { $0.name == "proofLensVignetting" } as? CIColorKernel
    }()

    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofLensVignetting(sample_t pixel, float2 center, float radius, float exponent,
                                                  float stops, destination dest) {
            float r = min(length(dest.coord() - center) / radius, 1.0);
            return float4(pixel.rgb * exp2(stops * pow(r, exponent)), pixel.a);
        }
    }
    }
    """
}
