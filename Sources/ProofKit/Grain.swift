import CoreImage

/// Film grain on the finished, cropped frame. The grain is sized relative to the frame, as
/// film's grain is to its negative, so a photo shows the same grain on the canvas, in a
/// thumbnail and in the export. See docs/decisions/0028-effects.md.
enum Grain {
    /// The frame's long edge, in grain units: a grain at Size 0 is about 0.8 units across and
    /// at Size 100 about 6, so on a 24-megapixel photo a unit is about one pixel.
    static let frameUnits: Float = 6000
    static let grainSize: ClosedRange<Float> = 0.8...6

    /// Applies `grain` to `image`, which is in linear light and is the whole cropped frame,
    /// starting at the origin. Values outside their ranges, which only a hand-edited sidecar can
    /// hold, are clamped. With Amount at 0 the image is returned as is.
    static func apply(_ grain: GrainAdjustments, to image: CIImage) -> CIImage {
        let amount = clamped(grain.amount, to: GrainAdjustments.amountRange) / 100
        guard amount > 0, let kernel else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return image }
        let size = Float(clamped(grain.size, to: GrainAdjustments.sizeRange) / 100)
        let roughness = Float(clamped(grain.roughness, to: GrainAdjustments.roughnessRange) / 100)
        // Grain units per pixel at this render's scale. Above 1 each pixel covers several grains
        // and shows their average, as the export does when it is shrunk to the same size.
        let unitsPerPixel = frameUnits / Float(max(extent.width, extent.height))
        return kernel.apply(extent: extent, arguments: [
            image, CIVector(x: extent.minX, y: extent.minY), unitsPerPixel,
            grainSize.lowerBound + (grainSize.upperBound - grainSize.lowerBound) * size,
            roughness * 0.6, Float(amount),
        ]) ?? image
    }

    static func clamped(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the grain
    /// then does nothing rather than failing the whole render.
    private static let kernel: CIColorKernel? = {
        let compiled = try? CIKernel.kernels(withMetalString: source)
        return compiled?.first { $0.name == "proofGrain" } as? CIColorKernel
    }()

    /// Value noise, in two octaves: grains of the chosen size and, mixed in by Roughness, grains
    /// half as large. An octave finer than a pixel is read at the pixel's size and weakened by
    /// how many grains the pixel averages, so a smaller render shows the grain the export will
    /// have when shrunk, not a coarser copy of it. The grain is added to gamma-encoded values,
    /// where it looks even, and is strongest in the low midtones, where a negative is thinnest.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" {
    namespace coreimage {
        // PCG hash, from Jarzynski and Olano, "Hash Functions for GPU Rendering" (2020).
        static uint pcg(uint v) {
            uint state = v * 747796405u + 2891336453u;
            uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
            return (word >> 22u) ^ word;
        }

        static float random(int2 cell, uint seed) {
            return float(pcg(uint(cell.x) ^ pcg(uint(cell.y) ^ pcg(seed)))) / 4294967295.0;
        }

        static float valueNoise(float2 p, uint seed) {
            float2 i = floor(p);
            float2 f = p - i;
            f = f * f * (3.0 - 2.0 * f);
            int2 c = int2(i);
            return mix(mix(random(c, seed), random(c + int2(1, 0), seed), f.x),
                       mix(random(c + int2(0, 1), seed), random(c + int2(1, 1), seed), f.x), f.y) - 0.5;
        }

        // Finer than a pixel, the noise is read on its lattice points, one random value per
        // pixel: the average of the grains the pixel covers, which don't depend on its
        // neighbors'. Between lattice points it would be a blend of four and too weak.
        static float octave(float2 position, float size, float footprint, uint seed) {
            if (footprint <= size) return valueNoise(position / size, seed);
            return valueNoise(position / footprint - 0.5, seed) * size / footprint;
        }

        [[stitchable]] float4 proofGrain(sample_t pixel, float2 origin, float unitsPerPixel, float size,
                                         float roughness, float amount, destination dest) {
            float2 position = (dest.coord() - origin) * unitsPerPixel;
            float footprint = max(unitsPerPixel, 1.0);
            float noise = mix(octave(position, size, footprint, 11u),
                              octave(position, size * 0.5, footprint, 23u), roughness);
            float3 rgb = pixel.rgb;
            float3 encoded = sign(rgb) * pow(abs(rgb), 1.0 / 2.2);
            float l = clamp(dot(encoded, float3(0.2126, 0.7152, 0.0722)), 0.0, 1.0);
            float weight = 0.3 + 4.0 * l * pow(1.0 - l, 1.5);
            encoded += noise * amount * 0.45 * weight;
            return float4(sign(encoded) * pow(abs(encoded), 2.2), pixel.a);
        }
    }
    }
    """
}
