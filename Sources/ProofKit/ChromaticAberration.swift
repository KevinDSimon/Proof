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
    /// photo in linear RGB, `width` by `height`, row by row.
    static func measure(_ pixels: [SIMD3<Float>], width: Int, height: Int) -> ChromaticAberration {
        guard pixels.count == width * height else { return ChromaticAberration() }
        return measure(rgba: pixels.flatMap { [$0.x, $0.y, $0.z, 1] }, width: width, height: height)
    }

    /// Measures as above from `rgba`, four floats a pixel, as Core Image renders them. Only edges
    /// that run across the direction from the center, away from it and not clipped, are compared,
    /// since those are the ones lateral aberration moves. A photo with too few such edges
    /// measures as 1. Written over raw buffers, since it reads millions of pixels and has to stay
    /// quick in a debug build too.
    static func measure(rgba: [Float], width: Int, height: Int) -> ChromaticAberration {
        let count = width * height
        guard width >= 16, height >= 16, rgba.count == count * 4 else { return ChromaticAberration() }
        // Square roots, so dark and bright edges count about alike, as they look.
        var red = [Float](repeating: 0, count: count)
        var green = red, blue = red
        var clipped = [Bool](repeating: false, count: count)
        rgba.withUnsafeBufferPointer { source in
            red.withUnsafeMutableBufferPointer { r in
                green.withUnsafeMutableBufferPointer { g in
                    blue.withUnsafeMutableBufferPointer { b in
                        clipped.withUnsafeMutableBufferPointer { c in
                            for i in 0..<count {
                                let x = source[4 * i], y = source[4 * i + 1], z = source[4 * i + 2]
                                r[i] = x > 0 ? x.squareRoot() : 0
                                g[i] = y > 0 ? y.squareRoot() : 0
                                b[i] = z > 0 ? z.squareRoot() : 0
                                c[i] = x > 0.9 || y > 0.9 || z > 0.9
                            }
                        }
                    }
                }
            }
        }

        // Every second pixel each way: edges are many pixels long, so this misses none.
        let cx = Float(width - 1) / 2, cy = Float(height - 1) / 2
        let inner = 0.3 * (cx * cx + cy * cy).squareRoot()
        var edges = Edges()
        green.withUnsafeBufferPointer { g in
            clipped.withUnsafeBufferPointer { c in
                for y in stride(from: 2, to: height - 2, by: 2) {
                    let dy = Float(y) - cy
                    for x in stride(from: 2, to: width - 2, by: 2) {
                        let dx = Float(x) - cx
                        let radius = (dx * dx + dy * dy).squareRoot()
                        if radius <= inner { continue }
                        let i = y * width + x
                        if c[i] || c[i - 1] || c[i + 1] || c[i - width] || c[i + width] { continue }
                        let ox = dx / radius, oy = dy / radius
                        let along = ((g[i + 1] - g[i - 1]) * ox + (g[i + width] - g[i - width]) * oy) / 2
                        if abs(along) <= 0.01 { continue }
                        edges.append(dx: dx, dy: dy, ox: ox, oy: oy, green: along)
                    }
                }
            }
        }
        guard edges.count >= 200 else { return ChromaticAberration() }
        // The strongest edges only: weak ones are mostly noise.
        edges.keepStrongest(20_000)
        let plane = Plane(width: width, height: height, cx: cx, cy: cy)
        return ChromaticAberration(red: Double(bestScale(of: red, in: plane, edges: edges)),
                                   blue: Double(bestScale(of: blue, in: plane, edges: edges)))
    }

    /// Edges as separate arrays, which a debug build reads much faster than an array of structs.
    private struct Edges {
        /// Offset from the center.
        var dx: [Float] = [], dy: [Float] = []
        /// The unit direction away from the center.
        var ox: [Float] = [], oy: [Float] = []
        /// Green's slope along that direction.
        var green: [Float] = []

        var count: Int { green.count }

        mutating func append(dx: Float, dy: Float, ox: Float, oy: Float, green slope: Float) {
            self.dx.append(dx); self.dy.append(dy); self.ox.append(ox); self.oy.append(oy); green.append(slope)
        }

        /// Keeps about the `limit` steepest, found from a histogram of slopes instead of a sort.
        mutating func keepStrongest(_ limit: Int) {
            guard count > limit else { return }
            let bins = 1024
            let steepest = green.reduce(0) { max($0, abs($1)) }
            var histogram = [Int](repeating: 0, count: bins)
            for slope in green { histogram[min(Int(abs(slope) / steepest * Float(bins)), bins - 1)] += 1 }
            var kept = 0, bin = bins
            while bin > 0, kept + histogram[bin - 1] <= limit {
                bin -= 1
                kept += histogram[bin]
            }
            let threshold = Float(bin) / Float(bins) * steepest
            var strongest = Edges()
            for i in 0..<count where abs(green[i]) >= threshold {
                strongest.append(dx: dx[i], dy: dy[i], ox: ox[i], oy: oy[i], green: green[i])
            }
            self = strongest
        }
    }

    private struct Plane {
        var width: Int
        var height: Int
        var cx: Float
        var cy: Float
    }

    /// The scale at which `channel`'s slopes, read at the scaled positions, best match green's:
    /// a coarse search, a fine one around its best, then a parabola through the finest three.
    private static func bestScale(of channel: [Float], in plane: Plane, edges: Edges) -> Float {
        let width = plane.width
        let maxX = Float(width - 1), maxY = Float(plane.height - 1)
        func score(_ scale: Float) -> Float {
            var product: Float = 0, energy: Float = 0
            channel.withUnsafeBufferPointer { values in
                edges.dx.withUnsafeBufferPointer { dx in
                    edges.dy.withUnsafeBufferPointer { dy in
                        edges.ox.withUnsafeBufferPointer { ox in
                            edges.oy.withUnsafeBufferPointer { oy in
                                edges.green.withUnsafeBufferPointer { green in
                                    for i in 0..<green.count {
                                        let px = plane.cx + dx[i] * scale, py = plane.cy + dy[i] * scale
                                        // Bilinear reads one pixel outward and one inward, held inside the photo.
                                        var taps: (Float, Float) = (0, 0)
                                        for side in 0..<2 {
                                            let sign: Float = side == 0 ? 1 : -1
                                            let x = min(max(px + sign * ox[i], 0), maxX)
                                            let y = min(max(py + sign * oy[i], 0), maxY)
                                            let x0 = min(Int(x), width - 2), y0 = min(Int(y), plane.height - 2)
                                            let fx = x - Float(x0), fy = y - Float(y0)
                                            let j = y0 * width + x0
                                            let top = values[j] + (values[j + 1] - values[j]) * fx
                                            let bottom = values[j + width] + (values[j + width + 1] - values[j + width]) * fx
                                            let value = top + (bottom - top) * fy
                                            if side == 0 { taps.0 = value } else { taps.1 = value }
                                        }
                                        let slope = (taps.0 - taps.1) / 2
                                        product += slope * green[i]
                                        energy += slope * slope
                                    }
                                }
                            }
                        }
                    }
                }
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
        let step: Float = 0.0001
        let fine = best(around: coarse.scale, step: step, steps: 4)
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
