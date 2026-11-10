import CoreImage

/// The Texture and Clarity sliders: raise (positive) or lower (negative) local contrast. Texture
/// works on fine detail a few pixels across; Clarity on larger areas, mostly in the midtones.
/// See docs/decisions/0017-texture-clarity.md.
enum TextureClarity {
    static let range: ClosedRange<Double> = -100...100

    /// Long edge, in pixels, of the map Clarity compares each pixel with. Like Highlights and
    /// Shadows, a fixed size makes the area a fixed share of the photo, so the canvas, thumbnails
    /// and export, which render at different scales, look alike.
    static let clarityMapSize: CGFloat = 320

    /// Texture's blur radius as a share of the photo's long edge, for the same reason. At a
    /// full-screen size this is about 2 pixels; at full sensor size about 6.
    static let textureRadius: CGFloat = 0.0007

    /// Applies both sliders to `image`, which is in linear light. Values outside -100…100, which
    /// only a hand-edited sidecar can hold, are clamped. With both at 0 the image is returned as is.
    static func apply(to image: CIImage, texture: Double, clarity: Double) -> CIImage {
        let texture = clamped(texture), clarity = clamped(clarity)
        guard texture != 0 || clarity != 0, let kernels else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1 else { return image }
        let longEdge = max(extent.width, extent.height)

        // Brightness of each pixel as stops from middle gray, mapped into 0…1 so the edge-aware
        // upsample can compare it.
        let brightness = kernels.brightness.apply(extent: extent, arguments: [image])!
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
        let back = CGAffineTransform(translationX: extent.minX, y: extent.minY)

        // Fine detail is the difference from a small blur.
        var fine = brightness
        if texture != 0 {
            fine = brightness.clampedToExtent()
                .applyingGaussianBlur(sigma: max(longEdge * textureRadius, 0.5))
                .cropped(to: extent)
        }

        // Larger areas: the brightness shrunk to a map, smoothed, and enlarged again following the
        // photo's edges, so raising Clarity doesn't draw halos along them.
        var area = brightness
        if clarity != 0 {
            let shrink = min(clarityMapSize / longEdge, 1)
            // Whole pixels, with the photo's edge repeated into the last one: a part pixel would
            // blend with nothing and draw a line along that edge.
            let mapRect = CGRect(x: 0, y: 0, width: (extent.width * shrink).rounded(.up),
                                 height: (extent.height * shrink).rounded(.up))
            let small = brightness.clampedToExtent()
                .transformed(by: origin, highQualityDownsample: true)
                .transformed(by: CGAffineTransform(scaleX: shrink, y: shrink), highQualityDownsample: true)
                .cropped(to: mapRect)
            let smoothed = small.clampedToExtent()
                .applyingGaussianBlur(sigma: 2)
                .cropped(to: small.extent)
            area = brightness
                .transformed(by: origin)
                .applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
                    "inputSmallImage": smoothed,
                    "inputSpatialSigma": 3,
                    "inputLumaSigma": 0.08,
                ])
                .transformed(by: back)
                .cropped(to: extent)
        }

        return kernels.adjust.apply(extent: extent, arguments: [
            image, fine, area, Float(strength(texture, raise: 0.9, lower: 0.5)),
            Float(strength(clarity, raise: 0.6, lower: 0.45)),
        ]) ?? image
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// How much of the detail is added at the slider's value: `raise` at +100, minus `lower` at -100.
    private static func strength(_ value: Double, raise: Double, lower: Double) -> Double {
        value / 100 * (value > 0 ? raise : lower)
    }

    private struct Kernels {
        let brightness: CIColorKernel
        let adjust: CIColorKernel
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the
    /// sliders then have no effect rather than failing the whole render.
    private static let kernels: Kernels? = {
        guard let compiled = try? CIKernel.kernels(withMetalString: source),
              let brightness = compiled.first(where: { $0.name == "proofDetailBrightness" }) as? CIColorKernel,
              let adjust = compiled.first(where: { $0.name == "proofTextureClarity" }) as? CIColorKernel
        else { return nil }
        return Kernels(brightness: brightness, adjust: adjust)
    }()

    /// Brightness is stored as stops from middle gray (0.18), from -10 to +4, mapped onto 0…1, as
    /// in Highlights and Shadows. Detail is a pixel's difference in stops from its blurred
    /// surroundings; each slider scales it and applies the result as a gain to red, green and blue
    /// alike, which keeps hue and saturation. Detail is limited to ±2 stops so a single bright
    /// point can't blow out. Clarity fades out in deep shadows and in highlights, so it shapes the
    /// midtones; Texture fades out only in deep shadows, where it would raise noise.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    namespace proofDetail {
        constant float lowStops = -10.0;
        constant float spanStops = 14.0;

        inline float stops(float3 rgb) {
            float luminance = dot(rgb, float3(0.2126, 0.7152, 0.0722));
            return log2(max(luminance, 1.0e-5) / 0.18);
        }

        inline float decoded(float value) {
            return value * spanStops + lowStops;
        }
    }

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofDetailBrightness(sample_t pixel) {
            float value = clamp((proofDetail::stops(pixel.rgb) - proofDetail::lowStops) / proofDetail::spanStops, 0.0, 1.0);
            return float4(value, value, value, 1.0);
        }

        [[stitchable]] float4 proofTextureClarity(sample_t pixel, sample_t fine, sample_t area, float texture, float clarity) {
            float own = proofDetail::stops(pixel.rgb);
            float fineStops = proofDetail::decoded(fine.r);
            float areaStops = proofDetail::decoded(area.r);
            float textureDetail = clamp(own - fineStops, -2.0, 2.0);
            float clarityDetail = clamp(own - areaStops, -2.0, 2.0);
            float textureWeight = smoothstep(-8.0, -5.0, fineStops);
            float clarityWeight = smoothstep(-7.0, -4.0, areaStops) * (1.0 - smoothstep(1.0, 3.0, areaStops));
            float gain = exp2(texture * textureDetail * textureWeight + clarity * clarityDetail * clarityWeight);
            return float4(pixel.rgb * gain, pixel.a);
        }
    }
    }
    """
}
