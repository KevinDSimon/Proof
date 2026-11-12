import CoreImage

/// Halation and Bloom: light from bright highlights, spread over the photo around them.
/// Halation is light that went through film and reflected off its base back into the red layer,
/// which leaves a red fringe around lights; Bloom is the soft glow of a diffusion filter, in
/// every color. Both are added in linear light before the tone stage, as the light reached the
/// film. See docs/decisions/0028-effects.md.
enum Glow {
    /// Long edge, in pixels, of the map the glow is spread on. The glow is wide and soft, so a
    /// small map holds all its detail; a fixed size makes the spread a fixed share of the photo,
    /// so the canvas, thumbnails and export look alike.
    static let mapSize: CGFloat = 1024

    /// Long edge, in pixels, of the map that tells a small light from a large bright area.
    static let surroundSize: CGFloat = 32

    /// Halation's spread at Size 0 and 100, as a share of the photo's long edge (a Gaussian's sigma).
    static let halationRadius: ClosedRange<CGFloat> = 0.004...0.04
    /// Bloom's spread at Size 0 and 100.
    static let bloomRadius: ClosedRange<CGFloat> = 0.01...0.1

    /// Applies `halation` and `bloom` to `image`, which is in linear light and is the whole photo
    /// before the crop, so light from outside the crop still spreads into it. Values outside their
    /// ranges, which only a hand-edited sidecar can hold, are clamped. With both Amounts at 0 the
    /// image is returned as is.
    static func apply(halation: GlowAdjustments, bloom: GlowAdjustments, to image: CIImage) -> CIImage {
        let halationAmount = clamped(halation.amount, to: GlowAdjustments.amountRange) / 100
        let bloomAmount = clamped(bloom.amount, to: GlowAdjustments.amountRange) / 100
        guard halationAmount > 0 || bloomAmount > 0, let kernels else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return image }
        let longEdge = max(extent.width, extent.height)
        let origin = CGAffineTransform(translationX: -extent.minX, y: -extent.minY)

        // Whole pixels, with the photo's edge repeated into the last one, as in TextureClarity.
        func shrunk(_ source: CIImage, to size: CGFloat) -> CIImage {
            let shrink = min(size / longEdge, 1)
            let rect = CGRect(x: 0, y: 0, width: (extent.width * shrink).rounded(.up),
                              height: (extent.height * shrink).rounded(.up))
            return source.clampedToExtent()
                .transformed(by: origin, highQualityDownsample: true)
                .transformed(by: CGAffineTransform(scaleX: shrink, y: shrink), highQualityDownsample: true)
                .cropped(to: rect)
        }
        // A map back over the photo. The glow is soft, so the linear sampling between map pixels
        // doesn't show.
        func enlarged(_ map: CIImage) -> CIImage {
            let grow = longEdge / max(map.extent.width, map.extent.height)
            return map.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: grow, y: grow)
                    .concatenating(CGAffineTransform(translationX: extent.minX, y: extent.minY)))
                .cropped(to: extent)
        }
        // A map blurred by `radius`, a share of the photo's long edge.
        func spread(_ map: CIImage, by radius: CGFloat) -> CIImage {
            let sigma = max(radius * max(map.extent.width, map.extent.height), 0.5)
            return map.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: map.extent)
        }
        // Wider than one Gaussian: scattered light falls off quickly near a light and then
        // lingers, so a narrow and a wide blur are averaged.
        func scatter(_ map: CIImage, by radius: CGFloat) -> CIImage {
            kernels.average.apply(extent: map.extent, arguments: [spread(map, by: radius / 3), spread(map, by: radius)])!
        }

        // The light that spreads: the highlights of each pixel of a copy twice the map's size,
        // found before the map is made so a small light keeps its brightness. A fixed size keeps
        // a zoomed render from reading the whole photo at full resolution, and the map is cached,
        // so changing an Amount or Size only blurs it again.
        let detailed = shrunk(image, to: mapSize * 2)
        let small = shrunk(image, to: surroundSize)
        let surround = small.clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: detailed.extent.width / small.extent.width,
                                               y: detailed.extent.height / small.extent.height))
            .cropped(to: detailed.extent)
        let found = kernels.source.apply(extent: detailed.extent, arguments: [detailed, surround])!
        let shrink = mapSize / max(detailed.extent.width, detailed.extent.height)
        let light = (shrink < 1
            ? found.clampedToExtent()
                .transformed(by: CGAffineTransform(scaleX: shrink, y: shrink), highQualityDownsample: true)
                .cropped(to: CGRect(x: 0, y: 0, width: (detailed.extent.width * shrink).rounded(.up),
                                    height: (detailed.extent.height * shrink).rounded(.up)))
            : found)
            .insertingIntermediate(cache: true)
        // Inside an evenly bright area the spread light is the area's own; only light that
        // spills past an edge shows. So each pixel gets what its surroundings send beyond its own.
        let own = enlarged(light)

        let size = (halation: clamped(halation.size, to: GlowAdjustments.sizeRange) / 100,
                    bloom: clamped(bloom.size, to: GlowAdjustments.sizeRange) / 100)
        let halationRadius = Self.halationRadius.lowerBound
            + (Self.halationRadius.upperBound - Self.halationRadius.lowerBound) * size.halation
        let bloomRadius = Self.bloomRadius.lowerBound + (Self.bloomRadius.upperBound - Self.bloomRadius.lowerBound) * size.bloom
        // With an Amount at 0 its maps are never drawn, so they cost nothing.
        let halationWide = halationAmount > 0 ? enlarged(scatter(light, by: halationRadius)) : own
        let halationNear = halationAmount > 0 ? enlarged(spread(light, by: halationRadius / 4)) : own
        let bloomLight = bloomAmount > 0 ? enlarged(scatter(light, by: bloomRadius)) : own
        let bloomAll = bloomAmount > 0 ? enlarged(spread(shrunk(image, to: mapSize).insertingIntermediate(cache: true), by: bloomRadius)) : image

        return kernels.add.apply(extent: extent, arguments: [
            image, own, halationWide, halationNear, bloomLight, bloomAll,
            Float(halationAmount), Float(bloomAmount),
        ]) ?? image
    }

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private struct Kernels {
        let source: CIColorKernel
        let average: CIColorKernel
        let add: CIColorKernel
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the effects
    /// then do nothing rather than failing the whole render.
    private static let kernels: Kernels? = {
        guard let compiled = try? CIKernel.kernels(withMetalString: source),
              let light = compiled.first(where: { $0.name == "proofGlowSource" }) as? CIColorKernel,
              let average = compiled.first(where: { $0.name == "proofGlowAverage" }) as? CIColorKernel,
              let add = compiled.first(where: { $0.name == "proofGlowAdd" }) as? CIColorKernel
        else { return nil }
        return Kernels(source: light, average: average, add: add)
    }()

    /// `proofGlowSource` keeps highlights, fading them in from a quarter of the clip point. A
    /// sensor stops at its clip point where film keeps recording, so a light near it is counted
    /// up to 16 times (4 stops) brighter, unless its surroundings are bright too: a clipped sky
    /// or window lost far less to clipping than a lamp, and boosting it would wash the photo out.
    ///
    /// `proofGlowAdd` adds the spread light. Halation reaches the red layer widest and the green
    /// a little, and is mostly the light's own red; Bloom spreads every color, and a diffusion
    /// filter also mixes in a little of all the light, which lowers contrast.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" {
    namespace coreimage {
        static float peak(float3 v) { return max(v.r, max(v.g, v.b)); }
        static float luma(float3 v) { return dot(v, float3(0.2126, 0.7152, 0.0722)); }

        [[stitchable]] float4 proofGlowSource(sample_t pixel, sample_t surround) {
            float3 v = max(pixel.rgb, 0.0);
            float p = peak(v);
            float nearClip = smoothstep(0.9, 1.0, p) * (1.0 - smoothstep(0.2, 0.6, peak(max(surround.rgb, 0.0))));
            float gain = smoothstep(0.25, 1.0, p) * mix(1.0, 16.0, nearClip);
            return float4(v * gain, 1.0);
        }

        [[stitchable]] float4 proofGlowAverage(sample_t a, sample_t b) {
            return float4((a.rgb + b.rgb) * 0.5, 1.0);
        }

        [[stitchable]] float4 proofGlowAdd(sample_t pixel, sample_t own, sample_t halationWide, sample_t halationNear,
                                           sample_t bloomLight, sample_t bloomAll, float halation, float bloom) {
            float3 rgb = pixel.rgb;
            if (halation > 0.0) {
                float3 wide = max(halationWide.rgb - own.rgb, 0.0);
                float3 near = max(halationNear.rgb - own.rgb, 0.0);
                float h = 0.5 * halation;
                rgb.r += h * mix(luma(wide), wide.r, 0.5);
                rgb.g += 0.2 * h * mix(luma(near), near.g, 0.5);
            }
            if (bloom > 0.0) {
                float3 spilled = max(bloomLight.rgb - own.rgb, 0.0);
                rgb = mix(rgb, max(bloomAll.rgb, 0.0), 0.12 * bloom) + 0.1 * bloom * spilled;
            }
            return float4(rgb, pixel.a);
        }
    }
    }
    """
}
