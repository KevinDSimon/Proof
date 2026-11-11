import CoreImage

/// Manual distortion correction for lenses without a profile, such as Leica M lenses. A simple
/// radial model about the center of the uncropped photo: the pixel at distance `r` from the center,
/// in units of the half diagonal, is read from `r × scale × (1 + k r²)`. The result is scaled so it
/// always fills the frame, keeping as much of the photo as it can. See
/// docs/decisions/0024-manual-lens-corrections.md.
enum LensDistortion {
    /// `k` with Distortion at 100. Lightroom's slider runs to about this strength, a fifth of the
    /// half diagonal at the corners. It also keeps the model one-to-one: the radius it reads from
    /// keeps growing out to the corners while `k` stays above -1/3.
    static let maxStrength = 0.2

    /// `k` for a Distortion value. Positive values correct barrel distortion, whose lines bow
    /// outward, by reading the corners from closer in.
    static func strength(_ distortion: Double) -> Double {
        let amount = min(max(distortion, LensCorrections.distortionRange.lowerBound), LensCorrections.distortionRange.upperBound)
        return -amount / 100 * maxStrength
    }

    /// The scale that makes the corrected photo fill a frame of `size`, with no empty edges, while
    /// keeping as much of it as possible. Since the radius read from grows steadily, the frame's
    /// corners and the middles of its sides are the only places that can reach past the photo.
    static func fillScale(strength k: Double, size: CGSize) -> Double {
        let diagonal = (size.width * size.width + size.height * size.height).squareRoot()
        guard diagonal > 0 else { return 1 }
        let halfWidth = size.width / diagonal, halfHeight = size.height / diagonal
        let reach = max(1 + k, 1 + k * halfWidth * halfWidth, 1 + k * halfHeight * halfHeight)
        return 1 / reach
    }

    /// Corrects `image`, the whole uncropped photo, for `distortion`. Returns it as is at 0 or `nil`.
    static func apply(_ distortion: Double?, to image: CIImage) -> CIImage {
        guard let distortion, distortion != 0, let kernel else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return image }
        let k = strength(distortion)
        let scale = fillScale(strength: k, size: extent.size)
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let radius = (extent.width * extent.width + extent.height * extent.height).squareRoot() / 2

        func source(of point: CGPoint) -> CGPoint {
            let dx = point.x - center.x, dy = point.y - center.y
            let f = scale * (1 + k * (dx * dx + dy * dy) / (radius * radius))
            return CGPoint(x: center.x + dx * f, y: center.y + dy * f)
        }
        // The map is one-to-one, so a rectangle's edges bound what it reads. Points along them,
        // with a margin for the curve between points and for the sampler.
        func region(for rect: CGRect) -> CGRect {
            let steps = 16
            var bounds = CGRect.null
            for i in 0...steps {
                let t = CGFloat(i) / CGFloat(steps)
                for point in [CGPoint(x: rect.minX + t * rect.width, y: rect.minY),
                              CGPoint(x: rect.minX + t * rect.width, y: rect.maxY),
                              CGPoint(x: rect.minX, y: rect.minY + t * rect.height),
                              CGPoint(x: rect.maxX, y: rect.minY + t * rect.height)] {
                    bounds = bounds.union(CGRect(origin: source(of: point), size: .zero))
                }
            }
            let margin = 4 + max(rect.width, rect.height) / CGFloat(steps) * CGFloat(abs(k))
            return bounds.insetBy(dx: -margin, dy: -margin)
        }
        return kernel.apply(extent: extent, roiCallback: { _, rect in region(for: rect) }, arguments: [
            image.clampedToExtent(), CIVector(cgPoint: center), Float(radius), Float(scale), Float(k),
        ])?.cropped(to: extent) ?? image
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the
    /// correction then has no effect rather than failing the whole render.
    private static let kernel: CIKernel? = {
        let compiled = try? CIKernel.kernels(withMetalString: source)
        return compiled?.first { $0.name == "proofLensDistortion" }
    }()

    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofLensDistortion(sampler src, float2 center, float radius, float scale, float k,
                                                  destination dest) {
            float2 d = dest.coord() - center;
            float2 u = d / radius;
            float f = scale * (1.0 + k * dot(u, u));
            return src.sample(src.transform(center + d * f));
        }
    }
    }
    """
}
