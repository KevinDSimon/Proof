import CoreGraphics
import Vision

/// Two quicker ways to level a photo than the straighten slider: a line drawn along something
/// that should be level or upright, and the horizon Vision finds. Both give a change to the
/// straighten angle, in degrees, with positive turning the photo clockwise, as `Crop.angle` does.
public enum Horizon {
    /// The change to the straighten angle that makes the line from `start` to `end` level, or
    /// upright when it is closer to vertical. The points are on the photo as shown, with y
    /// increasing downward. `nil` when the points are too close together to give an angle.
    public static func correction(from start: CGPoint, to end: CGPoint, minimumLength: Double = 1) -> Double? {
        let dx = end.x - start.x, dy = end.y - start.y
        guard hypot(dx, dy) >= minimumLength else { return nil }
        // With y downward, a positive angle is a line tilted clockwise from level.
        let tilt = atan2(dy, dx) * 180 / .pi
        // The nearest of level and upright, either way along the line: within ±45°.
        return -(tilt - (tilt / 90).rounded() * 90)
    }

    /// How far, in degrees clockwise, a pointer dragged from `start` to `end` has turned around
    /// `center`, with y increasing downward: what dragging outside a crop corner adds to the
    /// straighten angle, so the photo turns with the pointer. Within ±180°.
    public static func turn(around center: CGPoint, from start: CGPoint, to end: CGPoint) -> Double {
        let from = atan2(start.y - center.y, start.x - center.x)
        let to = atan2(end.y - center.y, end.x - center.x)
        let degrees = (to - from) * 180 / .pi
        return degrees - (degrees / 360).rounded() * 360
    }

    /// The straighten angle that levels the horizon Vision finds in `image`, which should show
    /// the photo turned and flipped but not straightened or cropped. `nil` when Vision finds no
    /// horizon, or one tilted further than straightening reaches.
    public static func correction(in image: CGImage) async throws -> Double? {
        guard let horizon = try await DetectHorizonRequest().perform(on: image) else { return nil }
        // Vision gives the turn that levels the horizon, counterclockwise with y upward: the
        // opposite sign to the straighten angle. `HorizonTests` pins the direction.
        let degrees = -horizon.angle.converted(to: .degrees).value
        guard Crop.angleRange.contains(degrees) else { return nil }
        return degrees
    }
}

/// A line drawn along something in the photo that should be level or upright, kept while the
/// crop tool's ruler is on so dragging an end refines the straighten angle. The ends are on the
/// photo turned and flipped but not straightened, in pixels from its center with y downward, so
/// the line stays on what it was drawn along as the photo turns under it.
public struct LevelLine: Equatable, Sendable {
    public var start: CGPoint
    public var end: CGPoint

    public init(start: CGPoint, end: CGPoint) {
        self.start = start
        self.end = end
    }

    /// The line through two points on screen, given from the photo's center at `scale` points per
    /// pixel, with the photo straightened by `angle` degrees clockwise.
    public init(shownFrom start: CGPoint, to end: CGPoint, scale: Double, angle: Double) {
        self.init(start: Self.photoPoint(of: start, scale: scale, angle: angle),
                  end: Self.photoPoint(of: end, scale: scale, angle: angle))
    }

    /// The straighten angle that makes the line level, or upright when it is closer to vertical.
    /// `nil` when the ends are too close together to give an angle.
    public var straightenAngle: Double? {
        Horizon.correction(from: start, to: end, minimumLength: 1)
    }

    /// The line with one end moved to `shown`, a point on screen given as in `init(shownFrom:)`.
    public func moving(isStart: Bool, to shown: CGPoint, scale: Double, angle: Double) -> LevelLine {
        let point = Self.photoPoint(of: shown, scale: scale, angle: angle)
        return isStart ? LevelLine(start: point, end: end) : LevelLine(start: start, end: point)
    }

    /// The whole line moved by `offset` on screen, which keeps its angle.
    public func moved(by offset: CGVector, scale: Double, angle: Double) -> LevelLine {
        let delta = Self.photoPoint(of: CGPoint(x: offset.dx, y: offset.dy), scale: scale, angle: angle)
        return LevelLine(start: CGPoint(x: start.x + delta.x, y: start.y + delta.y),
                         end: CGPoint(x: end.x + delta.x, y: end.y + delta.y))
    }

    /// Where `point` on the photo shows, from the photo's center on screen.
    public static func shownPoint(of point: CGPoint, scale: Double, angle: Double) -> CGPoint {
        let radians = angle * .pi / 180
        return CGPoint(x: scale * (point.x * cos(radians) - point.y * sin(radians)),
                       y: scale * (point.x * sin(radians) + point.y * cos(radians)))
    }

    /// The point on the photo that shows at `shown`, the inverse of `shownPoint`.
    public static func photoPoint(of shown: CGPoint, scale: Double, angle: Double) -> CGPoint {
        guard scale > 0 else { return .zero }
        let radians = -angle * .pi / 180
        return CGPoint(x: (shown.x * cos(radians) - shown.y * sin(radians)) / scale,
                       y: (shown.x * sin(radians) + shown.y * cos(radians)) / scale)
    }
}
