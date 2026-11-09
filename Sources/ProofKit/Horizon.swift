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
