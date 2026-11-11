import Foundation
import simd

/// A straight edge found in a photo, in pixels from the top left, with y increasing downward.
public struct LineSegment: Equatable, Sendable {
    public var start: SIMD2<Double>
    public var end: SIMD2<Double>

    public init(start: SIMD2<Double>, end: SIMD2<Double>) {
        self.start = start
        self.end = end
    }

    public var length: Double { simd_length(end - start) }
}

/// Finds straight edges in a photo for Upright. Vision finds horizons and contours but not
/// straight segments, so this follows the region-growing step of the LSD line segment detector
/// (von Gioi et al., 2012): neighboring pixels whose edges run the same way are grouped, and each
/// group long and thin enough to be a line becomes a segment. LSD's statistical test is replaced
/// by limits on length and fill, which is enough for the long edges of buildings that Upright
/// needs. See docs/decisions/0025-perspective.md.
enum LineDetector {
    /// The long side, in pixels, of the image lines are found in: a building's edges are long,
    /// and fine texture is better left out.
    static let measuringSize = 1024.0
    /// Pixels whose edges point further apart than this, in radians, aren't grouped.
    static let tolerance = 22.5 * Double.pi / 180
    /// The least change in brightness, out of 255 per pixel, that counts as an edge. LSD's
    /// threshold for its tolerance, which keeps out edges made only by noise and rounding.
    static let minimumGradient = 2 / sin(tolerance)
    /// The shortest segment kept, as a fraction of the image's long side: long enough to leave
    /// out the short edges of rock, foliage and texture.
    static let minimumLength = 0.06
    /// The least share of a segment's rectangle its pixels fill: lower is a curve or a texture.
    /// A soft photographed edge is a few pixels wide and a little ragged, so this is lenient.
    static let minimumFill = 0.5

    /// The segments in `gray`, row by row from the top, with values from 0 to 1.
    static func segments(in gray: [Float], width: Int, height: Int) -> [LineSegment] {
        guard width > 2, height > 2, gray.count == width * height else { return [] }
        let (w, h) = (width - 1, height - 1)
        var magnitude = [Double](repeating: 0, count: w * h)
        var angle = [Double](repeating: 0, count: w * h)
        var largest = 0.0
        gray.withUnsafeBufferPointer { a in
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * width + x
                    let (topLeft, topRight) = (Double(a[i]), Double(a[i + 1]))
                    let (bottomLeft, bottomRight) = (Double(a[i + width]), Double(a[i + width + 1]))
                    let gx = (topRight + bottomRight - topLeft - bottomLeft) * 255 / 2
                    let gy = (bottomLeft + bottomRight - topLeft - topRight) * 255 / 2
                    let m = (gx * gx + gy * gy).squareRoot()
                    magnitude[y * w + x] = m
                    // The direction the edge runs, across the gradient.
                    angle[y * w + x] = atan2(gx, -gy)
                    largest = max(largest, m)
                }
            }
        }
        guard largest > minimumGradient else { return [] }

        // Strongest edges first, as LSD seeds its regions, by sorting into bins.
        let bins = 1024
        var byStrength = [[Int32]](repeating: [], count: bins)
        var used = [Bool](repeating: false, count: w * h)
        for i in 0..<(w * h) {
            if magnitude[i] <= minimumGradient { used[i] = true; continue }
            byStrength[min(Int(magnitude[i] / largest * Double(bins - 1)), bins - 1)].append(Int32(i))
        }

        let shortest = minimumLength * Double(max(width, height))
        var found: [LineSegment] = []
        var region: [Int] = []
        for bin in byStrength.reversed() {
            for seed in bin where !used[Int(seed)] {
                region.removeAll(keepingCapacity: true)
                used[Int(seed)] = true
                region.append(Int(seed))
                var regionAngle = angle[Int(seed)]
                var (sumCos, sumSin) = (cos(regionAngle), sin(regionAngle))
                var next = 0
                while next < region.count {
                    let (x, y) = (region[next] % w, region[next] / w)
                    next += 1
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let (nx, ny) = (x + dx, y + dy)
                            guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
                            let n = ny * w + nx
                            guard !used[n], Self.difference(angle[n], regionAngle) < tolerance else { continue }
                            used[n] = true
                            region.append(n)
                            sumCos += cos(angle[n]); sumSin += sin(angle[n])
                            regionAngle = atan2(sumSin, sumCos)
                        }
                    }
                }
                guard Double(region.count) >= shortest,
                      let segment = Self.segment(fitting: region, width: w, magnitude: magnitude, angle: regionAngle),
                      segment.length >= shortest else { continue }
                found.append(segment)
            }
        }
        return found
    }

    /// The segment along a region's pixels, or `nil` when they don't make a thin straight band
    /// running the way their edges do.
    private static func segment(fitting region: [Int], width w: Int, magnitude: [Double],
                                angle: Double) -> LineSegment? {
        // Weighted by edge strength, so the band's center sits on the edge itself. The gradient
        // was measured between four pixels, so each sits a pixel in from its index.
        var total = 0.0, center = SIMD2<Double>(0, 0)
        for i in region {
            let weight = magnitude[i]
            total += weight
            center += weight * SIMD2(Double(i % w) + 1, Double(i / w) + 1)
        }
        guard total > 0 else { return nil }
        center /= total
        var (xx, xy, yy) = (0.0, 0.0, 0.0)
        for i in region {
            let d = SIMD2(Double(i % w) + 1, Double(i / w) + 1) - center
            let weight = magnitude[i]
            xx += weight * d.x * d.x; xy += weight * d.x * d.y; yy += weight * d.y * d.y
        }
        // The band's long axis: the covariance's larger eigenvector.
        let theta = 0.5 * atan2(2 * xy, xx - yy)
        let along = SIMD2(cos(theta), sin(theta))
        // The edges' own direction must agree with the band's.
        let edge = SIMD2(cos(angle), sin(angle))
        guard abs(simd_dot(along, edge)) > cos(tolerance) else { return nil }
        let across = SIMD2(-along.y, along.x)
        var (low, high, near, far) = (Double.infinity, -Double.infinity, Double.infinity, -Double.infinity)
        for i in region {
            let d = SIMD2(Double(i % w) + 1, Double(i / w) + 1) - center
            let l = simd_dot(d, along), t = simd_dot(d, across)
            low = min(low, l); high = max(high, l); near = min(near, t); far = max(far, t)
        }
        let length = high - low + 1, thickness = far - near + 1
        guard Double(region.count) / (length * thickness) >= minimumFill else { return nil }
        return LineSegment(start: center + low * along, end: center + high * along)
    }

    /// How far apart two directions are, in radians, from 0 to π.
    private static func difference(_ a: Double, _ b: Double) -> Double {
        var d = abs(a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d = 2 * .pi - d }
        return d
    }
}
