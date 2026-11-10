import Foundation

extension ToneCurve {
    /// The most points one channel's curve can have, as in Lightroom.
    public static let maximumPoints = 16

    public enum Channel: CaseIterable, Sendable {
        case rgb, red, green, blue
    }

    public subscript(channel: Channel) -> [CurvePoint] {
        get {
            switch channel {
            case .rgb: rgb
            case .red: red
            case .green: green
            case .blue: blue
            }
        }
        set {
            switch channel {
            case .rgb: rgb = newValue
            case .red: red = newValue
            case .green: green = newValue
            case .blue: blue = newValue
            }
        }
    }

    public subscript(levels channel: Channel) -> Levels {
        get {
            switch channel {
            case .rgb: levels.rgb
            case .red: levels.red
            case .green: levels.green
            case .blue: levels.blue
            }
        }
        set {
            switch channel {
            case .rgb: levels.rgb = newValue
            case .red: levels.red = newValue
            case .green: levels.green = newValue
            case .blue: levels.blue = newValue
            }
        }
    }

    public func isIdentity(_ channel: Channel) -> Bool {
        CurveSpline(self[channel]).isIdentity && LevelsMap(self[levels: channel]).isIdentity
    }

    /// One channel's whole curve: its levels, then its points.
    public func function(of channel: Channel) -> (Double) -> Double {
        let levels = LevelsMap(self[levels: channel]), spline = CurveSpline(self[channel])
        return { spline(levels($0)) }
    }

    public var isIdentity: Bool { Channel.allCases.allSatisfy(isIdentity) }
}

/// A channel's curve drawn through its points with monotone cubic (PCHIP) interpolation:
/// smooth, and between two points it never rises above or falls below them, so close points
/// can't make it overshoot and reverse tones. Left of the first point and right of the last it
/// stays flat at their outputs, which is how moving an end point inward clips.
///
/// Changing this changes how saved curves render, so it needs a `processVersion` bump.
public struct CurveSpline: Equatable, Sendable {
    let inputs: [Double]
    let outputs: [Double]
    let slopes: [Double]

    /// Points are clamped to 0…1 and sorted, and a point at the same input as an earlier one is
    /// dropped, so a sidecar edited by hand still gives a curve. Fewer than two points read as
    /// a straight line.
    public init(_ points: [CurvePoint]) {
        var xs: [Double] = [], ys: [Double] = []
        for point in points.map({ CurvePoint(Self.clamped($0.input), Self.clamped($0.output)) })
            .sorted(by: { $0.input < $1.input }) {
            if let last = xs.last, point.input - last < 1e-6 { continue }
            xs.append(point.input)
            ys.append(point.output)
        }
        if xs.count < 2 { (xs, ys) = ([0, 1], [0, 1]) }
        inputs = xs
        outputs = ys
        slopes = Self.slopes(xs, ys)
    }

    public var isIdentity: Bool { inputs == [0, 1] && outputs == [0, 1] }

    public func callAsFunction(_ x: Double) -> Double {
        if x <= inputs[0] { return outputs[0] }
        if x >= inputs[inputs.count - 1] { return outputs[outputs.count - 1] }
        var k = 0
        while inputs[k + 1] < x { k += 1 }
        let h = inputs[k + 1] - inputs[k], t = (x - inputs[k]) / h
        let t2 = t * t, t3 = t2 * t
        return (2 * t3 - 3 * t2 + 1) * outputs[k] + (t3 - 2 * t2 + t) * h * slopes[k]
            + (-2 * t3 + 3 * t2) * outputs[k + 1] + (t3 - t2) * h * slopes[k + 1]
    }

    private static func clamped(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }

    /// The slope at each point, following Fritsch and Butland as SciPy's PchipInterpolator does:
    /// zero where the curve turns, otherwise a weighted harmonic mean of the neighboring
    /// segments' slopes, and at the ends a three-point estimate kept from overshooting.
    private static func slopes(_ x: [Double], _ y: [Double]) -> [Double] {
        let n = x.count
        let h = (0..<n - 1).map { x[$0 + 1] - x[$0] }
        let d = (0..<n - 1).map { (y[$0 + 1] - y[$0]) / h[$0] }
        if n == 2 { return [d[0], d[0]] }
        var m = [Double](repeating: 0, count: n)
        for k in 1..<n - 1 where d[k - 1] * d[k] > 0 {
            let w1 = 2 * h[k] + h[k - 1], w2 = h[k] + 2 * h[k - 1]
            m[k] = (w1 + w2) / (w1 / d[k - 1] + w2 / d[k])
        }
        func end(_ h0: Double, _ h1: Double, _ d0: Double, _ d1: Double) -> Double {
            let s = ((2 * h0 + h1) * d0 - h0 * d1) / (h0 + h1)
            if s.sign != d0.sign || d0 == 0 { return 0 }
            if d0.sign != d1.sign, abs(s) > 3 * abs(d0) { return 3 * d0 }
            return s
        }
        m[0] = end(h[0], h[1], d[0], d[1])
        m[n - 1] = end(h[n - 2], h[n - 3], d[n - 2], d[n - 3])
        return m
    }
}

/// A channel's black, midtone and white handles as a function on 0…1: a straight stretch from
/// black to white, bent by a power so the midtone lands on 0.5. The handles are kept in order
/// and apart, and the midtone away from the ends, so a hand-edited sidecar still gives a curve.
///
/// Changing this changes how saved edits render, so it needs a `processVersion` bump.
public struct LevelsMap: Equatable, Sendable {
    public static let minimumGap = 0.02
    public static let midtoneRange: ClosedRange<Double> = 0.05...0.95

    public let black: Double
    public let white: Double
    public let midtone: Double
    let gamma: Double

    public init(_ levels: Levels) {
        func finite(_ v: Double, or fallback: Double) -> Double { v.isFinite ? v : fallback }
        black = min(max(finite(levels.black, or: 0), 0), 1 - Self.minimumGap)
        white = min(max(finite(levels.white, or: 1), black + Self.minimumGap), 1)
        midtone = min(max(finite(levels.midtone, or: 0.5), Self.midtoneRange.lowerBound), Self.midtoneRange.upperBound)
        gamma = log(0.5) / log(midtone)
    }

    public var isIdentity: Bool { black == 0 && white == 1 && midtone == 0.5 }

    public func callAsFunction(_ x: Double) -> Double {
        let t = min(max((x - black) / (white - black), 0), 1)
        return gamma == 1 ? t : pow(t, gamma)
    }

    /// The input that `callAsFunction` maps to `y`, which is where the editor draws a curve
    /// point whose own input is `y`.
    public func inverse(_ y: Double) -> Double {
        let t = min(max(y, 0), 1)
        return black + (white - black) * (gamma == 1 ? t : pow(t, 1 / gamma))
    }
}
