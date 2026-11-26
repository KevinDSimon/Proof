import Foundation

/// How the curve editor adds and moves a channel's points, in the curve's own 0–1 space. The
/// editor turns clicks and touches into these values; the rules here are the same on every
/// platform.
public enum CurveEditing {
    /// The closest two points can be, as a fraction of the graph's width.
    public static let minimumGap = 0.01

    /// `points` with a point added on the curve at `input`, so the curve doesn't change until the
    /// point is moved, and where it went; `nil` when the curve has all its points, or `input` is
    /// at an end or too close to a point.
    public static func adding(at input: Double, to points: [CurvePoint]) -> (points: [CurvePoint], index: Int)? {
        guard points.count < ToneCurve.maximumPoints else { return nil }
        let input = min(max(input, 0), 1)
        let index = points.firstIndex { $0.input > input } ?? points.count
        guard index > 0, index < points.count,
              input - points[index - 1].input >= minimumGap,
              points[index].input - input >= minimumGap else { return nil }
        var added = points
        added.insert(rounded(CurvePoint(input, CurveSpline(points)(input))), at: index)
        return (added, index)
    }

    /// `point` kept between the neighbors of the point at `index`, and inside the graph.
    public static func clamped(_ point: CurvePoint, at index: Int, in points: [CurvePoint]) -> CurvePoint {
        let low = index == 0 ? 0 : points[index - 1].input + minimumGap
        let high = index == points.count - 1 ? 1 : points[index + 1].input - minimumGap
        return rounded(CurvePoint(min(max(point.input, low), high), min(max(point.output, 0), 1)))
    }

    /// Whether the point at `index` can be removed: every point but the two ends.
    public static func canRemove(at index: Int, in points: [CurvePoint]) -> Bool {
        index > 0 && index < points.count - 1
    }

    /// Four decimals is finer than the lookup can show and keeps sidecars short.
    public static func rounded(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }

    public static func rounded(_ point: CurvePoint) -> CurvePoint {
        CurvePoint(rounded(point.input), rounded(point.output))
    }
}

/// Tells a double-click or double-tap from two separate presses: a second press on the same
/// target within `interval` of the first. A touch has no click count to ask, so the time between
/// presses is all there is.
public struct DoublePress<Target: Equatable> {
    public var interval: TimeInterval
    private var last: (target: Target, time: Date)?

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Records a press on `target`, and returns whether it completes a double press. A double
    /// press starts over, so a third press is a first again.
    public mutating func press(_ target: Target, at time: Date = Date()) -> Bool {
        if let last, last.target == target, time.timeIntervalSince(last.time) < interval {
            self.last = nil
            return true
        }
        last = (target, time)
        return false
    }

    /// Forgets the last press, as after a drag, which doesn't count toward a double press.
    public mutating func cancel() {
        last = nil
    }
}
