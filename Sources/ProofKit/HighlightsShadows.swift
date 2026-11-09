import CoreImage

/// The Highlights and Shadows sliders: brightens or darkens the bright and dark areas of the
/// photo, judged by their surroundings, so detail inside an area keeps its local contrast. See
/// docs/decisions/0009-highlights-shadows.md for why this is a custom kernel and not
/// `CIHighlightShadowAdjust`, which can only darken highlights.
enum HighlightsShadows {
    static let range: ClosedRange<Double> = -100...100

    /// Long edge, in pixels, of the low-resolution brightness map that decides how bright an area
    /// is. A fixed size makes the area a fixed share of the photo, so the canvas, thumbnails and
    /// export, which render at different scales, all treat the same area as bright or dark.
    static let mapSize: CGFloat = 96

    /// Applies both sliders to `image`, which is in linear light. Values outside -100…100, which
    /// only a hand-edited sidecar can hold, are clamped. With both at 0 the image is returned as is.
    static func apply(to image: CIImage, highlights: Double, shadows: Double) -> CIImage {
        let highlights = clamped(highlights), shadows = clamped(shadows)
        guard highlights != 0 || shadows != 0, let kernels else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }

        // Brightness of each pixel as stops from middle gray, mapped into 0…1 so the edge-aware
        // upsample can compare it.
        let brightness = kernels.brightness.apply(extent: extent, arguments: [image])!

        // The area's brightness: the brightness shrunk to a small map, smoothed, then enlarged
        // again following the photo's edges, so a bright sky doesn't spill onto a dark tree line.
        let shrink = min(mapSize / max(extent.width, extent.height), 1)
        let small = brightness
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY), highQualityDownsample: true)
            .transformed(by: CGAffineTransform(scaleX: shrink, y: shrink), highQualityDownsample: true)
        let smoothed = small.clampedToExtent()
            .applyingGaussianBlur(sigma: 1.5)
            .cropped(to: small.extent)
        let area = brightness
            .transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
                "inputSmallImage": smoothed,
                "inputSpatialSigma": 3,
                "inputLumaSigma": 0.1,
            ])
            .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
            .cropped(to: extent)

        return kernels.adjust.apply(extent: extent, arguments: [
            image, area, Float(highlights / 100), Float(shadows / 100),
        ]) ?? image
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private struct Kernels {
        let brightness: CIColorKernel
        let adjust: CIColorKernel
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the
    /// sliders then have no effect rather than failing the whole render.
    private static let kernels: Kernels? = {
        guard let compiled = try? CIKernel.kernels(withMetalString: source),
              let brightness = compiled.first(where: { $0.name == "proofBrightness" }) as? CIColorKernel,
              let adjust = compiled.first(where: { $0.name == "proofHighlightsShadows" }) as? CIColorKernel
        else { return nil }
        return Kernels(brightness: brightness, adjust: adjust)
    }()

    /// Brightness is stored as stops from middle gray (0.18), from -10 to +4, mapped onto 0…1.
    /// The gains are in stops and applied to red, green and blue alike, which keeps hue and
    /// saturation in linear light. Each slider's weight follows the area's brightness: Shadows
    /// acts fully about 4.5 stops below middle gray and fades out just above it; Highlights fades
    /// in just below middle gray and acts fully 2.5 stops above. Darkening reaches further than
    /// brightening, because recovering a bright sky or lifting a dark corner is what these
    /// sliders are mostly used for.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    namespace proof {
        constant float lowStops = -10.0;
        constant float spanStops = 14.0;

        inline float stops(float3 rgb) {
            float luminance = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            return log2(max(luminance, 1.0e-5) / 0.18);
        }
    }

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofBrightness(sample_t pixel) {
            float value = clamp((proof::stops(pixel.rgb) - proof::lowStops) / proof::spanStops, 0.0, 1.0);
            return float4(value, value, value, 1.0);
        }

        [[stitchable]] float4 proofHighlightsShadows(sample_t pixel, sample_t area, float highlights, float shadows) {
            float areaStops = area.r * proof::spanStops + proof::lowStops;
            float highlightWeight = smoothstep(-0.5, 2.5, areaStops);
            float shadowWeight = 1.0 - smoothstep(-4.5, 1.0, areaStops);
            float highlightStops = highlights * (highlights < 0.0 ? 1.5 : 0.75);
            float shadowStops = shadows * (shadows > 0.0 ? 2.0 : 1.0);
            float gain = exp2(highlightStops * highlightWeight + shadowStops * shadowWeight);
            return float4(pixel.rgb * gain, pixel.a);
        }
    }
    }
    """
}
