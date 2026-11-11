import Foundation
import simd

/// Chooses the Vertical, Horizontal and Rotate sliders that make lines in a photo upright and
/// level, as Lightroom's Upright does. The lines are either the segments `LineDetector` finds or
/// the guides a person draws. See docs/decisions/0025-perspective.md.
public enum Upright {
    /// Lines within this many degrees of upright or level are taken as meant to be.
    static let reach = 25.0
    /// How far, as the sine of the angle, a line may stay off upright or level before it counts
    /// for less: about 2°. Lines much further off, such as a roof's slope, then barely count.
    static let softness = 0.035
    /// Auto corrects tilts up to this much in full, and only part of the rest, since a building
    /// corrected all the way from a steep angle looks stretched.
    static let autoFullTilt = 20.0
    /// The share of a tilt beyond `autoFullTilt` that Auto corrects.
    static let autoBeyond = 0.6
    /// The least share of the lines' length that must run level before Auto corrects the
    /// horizontal perspective.
    static let autoHorizontalShare = 0.2

    /// The sliders that `mode` chooses for `segments` in a photo of `size`, starting from
    /// `transform`, whose other sliders are kept. Guided reads `transform.guides` instead of the
    /// segments. `nil` when there are no lines to go by.
    public static func solve(_ mode: UprightMode, segments: [LineSegment], size: CGSize,
                             from transform: PerspectiveTransform) -> PerspectiveTransform? {
        var lines: [Line]
        if mode == .guided {
            let scale = SIMD2(Double(size.width), Double(size.height))
            lines = transform.guides.map {
                let segment = LineSegment(start: SIMD2($0.start.x, $0.start.y) * scale, end: SIMD2($0.end.x, $0.end.y) * scale)
                return Line(segment: segment, upright: segment.isCloserToUpright, weight: 1)
            }
        } else {
            lines = segments.compactMap { segment in
                let angle = segment.tilt
                if abs(angle) <= reach { return Line(segment: segment, upright: false, weight: segment.length) }
                if abs(abs(angle) - 90) <= reach { return Line(segment: segment, upright: true, weight: segment.length) }
                return nil
            }
        }
        guard !lines.isEmpty else { return nil }

        let uprightCount = lines.filter(\.upright).count, levelCount = lines.count - uprightCount
        var free: Set<Parameter> = [.rotate]
        switch mode {
        case .level:
            break
        case .vertical:
            if uprightCount >= 2 { free.insert(.vertical) }
        case .full:
            if uprightCount >= 2 { free.insert(.vertical) }
            if levelCount >= 2 { free.insert(.horizontal) }
        case .auto:
            if uprightCount >= 2 { free.insert(.vertical) }
            let total = lines.reduce(0) { $0 + $1.weight }
            let level = lines.filter { !$0.upright }.reduce(0) { $0 + $1.weight }
            if levelCount >= 2, level >= autoHorizontalShare * total { free.insert(.horizontal) }
        case .guided:
            // Two lines one way pin that tilt and the turn; one more line the other way is
            // enough for the other tilt once the turn is pinned.
            if uprightCount >= 2 || (uprightCount >= 1 && levelCount >= 2) { free.insert(.vertical) }
            if levelCount >= 2 || (levelCount >= 1 && uprightCount >= 2) { free.insert(.horizontal) }
        }
        let parameters = Parameter.allCases.filter(free.contains)
        // Guides are meant exactly; found lines include some that aren't, which count for less
        // the further they stay off.
        let robust = mode != .guided

        var values = SIMD3<Double>(0, 0, 0)
        for _ in 0..<(robust ? 4 : 1) {
            values = refine(values, lines: &lines, parameters: parameters, size: size, robust: robust, base: transform)
        }
        if mode == .auto {
            func held(_ tilt: Double) -> Double {
                abs(tilt) <= autoFullTilt ? tilt : (autoFullTilt + (abs(tilt) - autoFullTilt) * autoBeyond) * (tilt < 0 ? -1 : 1)
            }
            values.x = held(values.x)
            values.y = held(values.y)
        }
        var result = transform.with(vertical: values.x, horizontal: values.y, rotate: values.z)
        result.upright = mode
        if mode != .guided { result.guides = [] }
        return result
    }

    enum Parameter: Int, CaseIterable { case vertical, horizontal, rotate }

    struct Line {
        var segment: LineSegment
        var upright: Bool
        var weight: Double
        /// The weight after robust reweighting, from `weight`.
        var current: Double = 0

        init(segment: LineSegment, upright: Bool, weight: Double) {
            self.segment = segment
            self.upright = upright
            self.weight = weight
            current = weight
        }
    }

    /// One round of reweighting, then Gauss–Newton steps toward the sliders that least turn the
    /// lines off upright or level. The tilts are in slider units, the turn in degrees.
    private static func refine(_ start: SIMD3<Double>, lines: inout [Line], parameters: [Parameter], size: CGSize,
                               robust: Bool, base: PerspectiveTransform) -> SIMD3<Double> {
        func map(_ v: SIMD3<Double>) -> simd_double3x3 {
            let t = base.with(vertical: v.x, horizontal: v.y, rotate: v.z)
            let (w, h) = (Double(size.width), Double(size.height))
            return PerspectiveTransform.recentered(t.tilt(for: size)) * PerspectiveTransform.translation(-w / 2, -h / 2)
        }
        func residual(_ line: Line, _ m: simd_double3x3) -> Double {
            let p = PerspectiveTransform.apply(m, to: line.segment.start)
            let q = PerspectiveTransform.apply(m, to: line.segment.end)
            let d = q - p, length = simd_length(d)
            guard length > 0 else { return 0 }
            return (line.upright ? d.x : d.y) / length
        }
        if robust {
            let m = map(start)
            for i in lines.indices {
                let r = residual(lines[i], m) / softness
                lines[i].current = lines[i].weight / (1 + r * r)
            }
        }
        var v = start
        for _ in 0..<12 {
            let m = map(v)
            let residuals = lines.map { residual($0, m) }
            // Columns of the Jacobian, by finite differences: a hundredth of a slider step.
            var jacobian: [[Double]] = []
            for parameter in parameters {
                var nudged = v
                nudged[parameter.rawValue] += 0.01
                let mn = map(nudged)
                jacobian.append(lines.indices.map { (residual(lines[$0], mn) - residuals[$0]) / 0.01 })
            }
            let n = parameters.count
            var normal = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
            var gradient = [Double](repeating: 0, count: n)
            for i in lines.indices {
                for a in 0..<n {
                    gradient[a] += lines[i].current * jacobian[a][i] * residuals[i]
                    for b in 0..<n { normal[a][b] += lines[i].current * jacobian[a][i] * jacobian[b][i] }
                }
            }
            // A little damping keeps a step from overshooting when the lines barely pin a value.
            for a in 0..<n { normal[a][a] = normal[a][a] * 1.001 + 1e-12 }
            guard let step = solve(normal, gradient) else { break }
            for (a, parameter) in parameters.enumerated() { v[parameter.rawValue] -= step[a] }
            v.x = PerspectiveTransform.clamp(v.x, PerspectiveTransform.tiltRange)
            v.y = PerspectiveTransform.clamp(v.y, PerspectiveTransform.tiltRange)
            v.z = PerspectiveTransform.clamp(v.z, PerspectiveTransform.rotateRange)
            if step.allSatisfy({ abs($0) < 1e-4 }) { break }
        }
        return v
    }

    /// `x` with `a x = b`, by Gaussian elimination; `nil` when `a` is singular.
    private static func solve(_ a: [[Double]], _ b: [Double]) -> [Double]? {
        var m = a, x = b
        let n = b.count
        for column in 0..<n {
            guard let pivot = (column..<n).max(by: { abs(m[$0][column]) < abs(m[$1][column]) }),
                  abs(m[pivot][column]) > 1e-15 else { return nil }
            m.swapAt(column, pivot); x.swapAt(column, pivot)
            for row in 0..<n where row != column {
                let factor = m[row][column] / m[column][column]
                for k in column..<n { m[row][k] -= factor * m[column][k] }
                x[row] -= factor * x[column]
            }
        }
        return (0..<n).map { x[$0] / m[$0][$0] }
    }
}

extension LineSegment {
    /// The segment's angle from level, in degrees, from -90 to 90, with y downward.
    var tilt: Double {
        var d = end - start
        if d.x < 0 { d = -d }
        return atan2(d.y, d.x) * 180 / .pi
    }

    var isCloserToUpright: Bool { abs(tilt) > 45 }
}
