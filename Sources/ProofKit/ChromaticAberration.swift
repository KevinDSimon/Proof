import CoreImage
import Foundation

/// Lateral chromatic aberration, measured from the photo: the lens focuses red and blue at a
/// slightly different size from green, which shows as colored fringes along edges that grow
/// toward the corners. Each value is the scale, about the photo's center, at which that channel
/// is read so it lines up with green: 1 leaves it in place. See
/// docs/decisions/0023-chromatic-aberration.md.
public struct ChromaticAberration: Codable, Equatable, Sendable {
    public var red: Double
    public var blue: Double

    /// Far beyond any real lens, so a hand-edited value can't smear the photo.
    public static let range = 0.99...1.01

    public init(red: Double = 1, blue: Double = 1) {
        self.red = red
        self.blue = blue
    }

    /// The long edge of the render it is measured on. Fringes are about a pixel wide at full
    /// resolution, so a smaller render loses them.
    static let measuringSize = 3000.0

    /// Measures the scales that line red and blue up with green in `pixels`, the whole uncropped
    /// photo in linear RGB, `width` by `height`, row by row. Only edges that run across the
    /// direction from the center, away from it and not clipped, are compared, since those are
    /// the ones lateral aberration moves. A photo with too few such edges measures as 1.
    static func measure(_ pixels: [SIMD3<Float>], width: Int, height: Int) -> ChromaticAberration {
        guard width >= 16, height >= 16, pixels.count == width * height else { return ChromaticAberration() }
        // Square roots, so dark and bright edges count about alike, as they look.
        var red = [Float](repeating: 0, count: pixels.count)
        var green = red, blue = red
        var clipped = [Bool](repeating: false, count: pixels.count)
        for (i, p) in pixels.enumerated() {
            red[i] = max(p.x, 0).squareRoot()
            green[i] = max(p.y, 0).squareRoot()
            blue[i] = max(p.z, 0).squareRoot()
            clipped[i] = max(p.x, p.y, p.z) > 0.9
        }

        let center = SIMD2(Float(width - 1) / 2, Float(height - 1) / 2)
        let halfDiagonal = (center * center).sum().squareRoot()
        var edges: [Edge] = []
        for y in 2..<(height - 2) {
            for x in 2..<(width - 2) {
                let i = y * width + x
                if clipped[i] || clipped[i - 1] || clipped[i + 1] || clipped[i - width] || clipped[i + width] { continue }
                let offset = SIMD2(Float(x), Float(y)) - center
                let radius = (offset * offset).sum().squareRoot()
                guard radius > 0.3 * halfDiagonal else { continue }
                let outward = offset / radius
                let gradient = SIMD2(green[i + 1] - green[i - 1], green[i + width] - green[i - width]) / 2
                let along = (gradient * outward).sum()
                guard abs(along) > 0.01 else { continue }
                edges.append(Edge(position: SIMD2(Float(x), Float(y)), outward: outward, green: along))
            }
        }
        // The strongest edges only: weak ones are mostly noise.
        let count = 40_000
        guard edges.count >= 200 else { return ChromaticAberration() }
        if edges.count > count {
            edges.sort { abs($0.green) > abs($1.green) }
            edges.removeLast(edges.count - count)
        }
        let image = Plane(width: width, height: height)
        return ChromaticAberration(red: Double(bestScale(of: red, in: image, edges: edges, center: center)),
                                   blue: Double(bestScale(of: blue, in: image, edges: edges, center: center)))
    }

    private struct Edge {
        var position: SIMD2<Float>
        var outward: SIMD2<Float>
        /// Green's slope along `outward`.
        var green: Float
    }

    private struct Plane {
        var width: Int
        var height: Int

        /// Bilinear, with positions outside held at the edge.
        func sample(_ values: [Float], at p: SIMD2<Float>) -> Float {
            let x = min(max(p.x, 0), Float(width - 1)), y = min(max(p.y, 0), Float(height - 1))
            let x0 = min(Int(x), width - 2), y0 = min(Int(y), height - 2)
            let fx = x - Float(x0), fy = y - Float(y0)
            let i = y0 * width + x0
            let top = values[i] + (values[i + 1] - values[i]) * fx
            let bottom = values[i + width] + (values[i + width + 1] - values[i + width]) * fx
            return top + (bottom - top) * fy
        }
    }

    /// The scale at which `channel`'s slopes, read at the scaled positions, best match green's:
    /// a coarse search, a fine one around its best, then a parabola through the finest three.
    private static func bestScale(of channel: [Float], in image: Plane, edges: [Edge], center: SIMD2<Float>) -> Float {
        func score(_ scale: Float) -> Float {
            var product: Float = 0, energy: Float = 0
            for edge in edges {
                let p = center + (edge.position - center) * scale
                let slope = (image.sample(channel, at: p + edge.outward) - image.sample(channel, at: p - edge.outward)) / 2
                product += slope * edge.green
                energy += slope * slope
            }
            return energy > 0 ? product / energy.squareRoot() : 0
        }
        func best(around middle: Float, step: Float, steps: Int) -> (scale: Float, score: Float) {
            var found = (scale: middle, score: -Float.infinity)
            for k in -steps...steps {
                let scale = middle + Float(k) * step
                let s = score(scale)
                if s > found.score { found = (scale, s) }
            }
            return found
        }
        let coarse = best(around: 1, step: 0.0004, steps: 10)
        let step: Float = 0.00005
        let fine = best(around: coarse.scale, step: step, steps: 8)
        let before = score(fine.scale - step), after = score(fine.scale + step)
        let curvature = before - 2 * fine.score + after
        let shift = curvature < 0 ? min(max((before - after) / (2 * curvature), -0.5), 0.5) : 0
        let scale = fine.scale + shift * step
        return min(max(scale, Float(range.lowerBound)), Float(range.upperBound))
    }

    /// `image`, the decoded photo, with red and blue read at their scales about its center.
    /// Scales of 1 return it as is.
    static func apply(_ aberration: ChromaticAberration?, to image: CIImage) -> CIImage {
        guard let aberration, aberration != ChromaticAberration(), let kernel else { return image }
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return image }
        let red = min(max(aberration.red, range.lowerBound), range.upperBound)
        let blue = min(max(aberration.blue, range.lowerBound), range.upperBound)
        let center = CGPoint(x: extent.midX, y: extent.midY)
        func scaled(_ rect: CGRect, by scale: Double) -> CGRect {
            rect.applying(CGAffineTransform(translationX: -center.x, y: -center.y)
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: center.x, y: center.y)))
        }
        return kernel.apply(extent: extent, roiCallback: { _, rect in
            rect.union(scaled(rect, by: red)).union(scaled(rect, by: blue)).insetBy(dx: -2, dy: -2)
        }, arguments: [image.clampedToExtent(), CIVector(cgPoint: center), Float(red), Float(blue)])?
            .cropped(to: extent) ?? image
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the
    /// correction then has no effect rather than failing the whole render.
    private static let kernel: CIKernel? = {
        let compiled = try? CIKernel.kernels(withMetalString: source)
        return compiled?.first { $0.name == "proofChromaticAberration" }
    }()

    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofChromaticAberration(sampler src, float2 center, float red, float blue,
                                                       destination dest) {
            float2 d = dest.coord();
            float4 pixel = src.sample(src.transform(d));
            pixel.r = src.sample(src.transform(center + (d - center) * red)).r;
            pixel.b = src.sample(src.transform(center + (d - center) * blue)).b;
            return pixel;
        }
    }
    }
    """
}
