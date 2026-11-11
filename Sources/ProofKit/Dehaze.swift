import CoreImage

/// The Dehaze slider: removes (positive) or adds (negative) atmospheric haze, using the dark-channel
/// prior. See docs/decisions/0020-dehaze.md.
enum Dehaze {
    static let range: ClosedRange<Double> = -100...100

    /// Long edge, in pixels, of the map the haze is measured on. As for Clarity, a fixed size makes
    /// the measured areas a fixed share of the photo, so the canvas, thumbnails and export look alike.
    static let mapSize: CGFloat = 320

    /// Applies the slider to `image`, which is in linear light. Values outside -100…100, which only a
    /// hand-edited sidecar can hold, are clamped. At 0 the image is returned as is.
    static func apply(to image: CIImage, amount: Double) -> CIImage {
        let amount = clamped(amount)
        guard amount != 0, let kernels else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let back = CGAffineTransform(translationX: extent.minX, y: extent.minY)

        // The photo shrunk to the map, in whole pixels with its edge repeated into the last one.
        let shrink = min(mapSize / max(extent.width, extent.height), 1)
        let mapRect = CGRect(x: 0, y: 0, width: (extent.width * shrink).rounded(.up),
                             height: (extent.height * shrink).rounded(.up))
        let small = image.clampedToExtent()
            .transformed(by: origin, highQualityDownsample: true)
            .transformed(by: CGAffineTransform(scaleX: shrink, y: shrink), highQualityDownsample: true)
            .cropped(to: mapRect)

        // The dark channel: each pixel's darkest channel, then the darkest in its surroundings.
        // Haze lifts it; clear areas almost always hold something dark in one channel.
        let darkest = kernels.darkest.apply(extent: mapRect, arguments: [small])!
        let dark = minimum(darkest, in: mapRect)

        // The haze's color: the average of the map's pixels whose dark channel is near the highest.
        let highest = dark.applyingFilter("CIAreaMaximum", parameters: [kCIInputExtentKey: CIVector(cgRect: mapRect)])
            .clampedToExtent()
        let weighted = kernels.hazeWeight.apply(extent: mapRect, arguments: [small, dark, highest])!
        let airlight = weighted.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: mapRect)])
            .clampedToExtent()

        // How much haze each area holds: the dark channel of the photo divided by the haze's color,
        // smoothed, and enlarged following the photo's edges so the change doesn't spill across them.
        let haze = minimum(kernels.hazeDarkest.apply(extent: mapRect, arguments: [small, airlight])!, in: mapRect)
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 1.5)
            .cropped(to: mapRect)
        let guide = kernels.guide.apply(extent: extent, arguments: [image])!
        let hazeMap = guide
            .transformed(by: origin)
            .applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
                "inputSmallImage": haze,
                "inputSpatialSigma": 3,
                "inputLumaSigma": 0.08,
            ])
            .transformed(by: back)
            .cropped(to: extent)

        return kernels.adjust.apply(extent: extent, arguments: [
            image, hazeMap, airlight, Float(amount / 100),
        ]) ?? image
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The darkest value within 3 map pixels, about 1% of the photo's long edge.
    private static func minimum(_ image: CIImage, in rect: CGRect) -> CIImage {
        image.clampedToExtent()
            .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: 3])
            .cropped(to: rect)
    }

    private struct Kernels {
        let darkest: CIColorKernel
        let hazeWeight: CIColorKernel
        let hazeDarkest: CIColorKernel
        let guide: CIColorKernel
        let adjust: CIColorKernel
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the slider
    /// then has no effect rather than failing the whole render.
    private static let kernels: Kernels? = {
        guard let compiled = try? CIKernel.kernels(withMetalString: source) else { return nil }
        func kernel(_ name: String) -> CIColorKernel? { compiled.first { $0.name == name } as? CIColorKernel }
        guard let darkest = kernel("proofDehazeDarkest"), let hazeWeight = kernel("proofDehazeWeight"),
              let hazeDarkest = kernel("proofDehazeHazeDarkest"), let guide = kernel("proofDehazeGuide"),
              let adjust = kernel("proofDehaze")
        else { return nil }
        return Kernels(darkest: darkest, hazeWeight: hazeWeight, hazeDarkest: hazeDarkest, guide: guide, adjust: adjust)
    }()

    /// The haze model: a pixel is the clear scene `J`, dimmed by how much light gets through `t`,
    /// plus the haze's color `A` filling in the rest: `I = J·t + A·(1 − t)`. With the haze map as
    /// `1 − t`, removing haze solves for `J`; adding it moves the pixel further toward `A`.
    ///
    /// The haze's weight is written as alpha with color multiplied by it, so Core Image's average
    /// of the weighted pixels, read back as premultiplied color, is their weighted average.
    /// Removing never lets through less than 30% of the light, which keeps the haziest areas, such
    /// as sky, from turning dark or noisy. Adding fills thicker haze where there is some already,
    /// and a thinner veil everywhere.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofDehazeDarkest(sample_t pixel) {
            float value = max(min(min(pixel.r, pixel.g), pixel.b), 0.0);
            return float4(value, value, value, 1.0);
        }

        [[stitchable]] float4 proofDehazeWeight(sample_t pixel, sample_t dark, sample_t highest) {
            float weight = smoothstep(highest.r * 0.85, highest.r, dark.r) + 1.0e-4;
            return float4(max(pixel.rgb, 0.0) * weight, weight);
        }

        [[stitchable]] float4 proofDehazeHazeDarkest(sample_t pixel, sample_t airlight) {
            float3 haze = max(airlight.rgb / max(airlight.a, 1.0e-6), 1.0e-4);
            float3 ratio = max(pixel.rgb, 0.0) / haze;
            float value = clamp(min(min(ratio.r, ratio.g), ratio.b), 0.0, 1.0);
            return float4(value, value, value, 1.0);
        }

        // Stops from middle gray, from -10 to +4, mapped onto 0…1, as in Texture and Clarity.
        [[stitchable]] float4 proofDehazeGuide(sample_t pixel) {
            float luminance = dot(pixel.rgb, float3(0.2126, 0.7152, 0.0722));
            float value = clamp((log2(max(luminance, 1.0e-5) / 0.18) + 10.0) / 14.0, 0.0, 1.0);
            return float4(value, value, value, 1.0);
        }

        [[stitchable]] float4 proofDehaze(sample_t pixel, sample_t hazeMap, sample_t airlight, float amount) {
            float3 haze = max(airlight.rgb / max(airlight.a, 1.0e-6), 0.0);
            float thickness = clamp(hazeMap.r, 0.0, 1.0);
            float3 rgb;
            if (amount > 0.0) {
                float through = 1.0 - 0.7 * amount * thickness;
                rgb = max((pixel.rgb - haze) / through + haze, 0.0);
            } else {
                float through = 1.0 + 0.5 * amount * (0.2 + 0.8 * thickness);
                rgb = pixel.rgb * through + haze * (1.0 - through);
            }
            return float4(rgb, pixel.a);
        }
    }
    }
    """
}
