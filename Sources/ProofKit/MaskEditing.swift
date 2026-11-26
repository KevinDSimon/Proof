import CoreGraphics
import Foundation

/// What part of a mask a press on the Masks tool is on.
public enum MaskPart: Equatable, Sendable {
    case linearStart, linearEnd, linearTurn
    case radialWidth, radialHeight, radialTurn, radialInside
    /// A mask's pin, by its place in the edit's layers.
    case pin(Int)
}

/// How far the Masks tool's pins, handles and lines reach for a press: a pointer's is a few
/// points, while a finger's is 22 points, for the 44-point targets of Apple's Human Interface
/// Guidelines.
public enum MaskReach: Sendable {
    case pointer
    case touch

    /// From a handle, or square to a linear gradient's line, in points.
    public var handle: Double {
        switch self {
        case .pointer: 7
        case .touch: 22
        }
    }

    /// From a pin's center, in points.
    public var pin: Double {
        switch self {
        case .pointer: 8
        case .touch: 22
        }
    }

    /// The radius a pin is drawn at, in points.
    public var pinRadius: Double {
        switch self {
        case .pointer: 5
        case .touch: 7
        }
    }

    /// How far the radial gradient's turning handle sits above its ellipse, in points: far
    /// enough on touch that it and the height handle don't share a finger's reach.
    public var turnOffset: Double {
        switch self {
        case .pointer: 22
        case .touch: 44
        }
    }

    /// The nearest of `distances` within `limit`, in the order they're tried, so the first
    /// wins a tie; `nil` when none is within reach.
    public static func nearest(_ distances: [Double], within limit: Double) -> Int? {
        var best: Int?
        for (index, distance) in distances.enumerated() where distance <= limit {
            if best == nil || distance < distances[best!] { best = index }
        }
        return best
    }
}

extension Mask {
    /// The mask with `part` dragged from `start` to `end`, both points of the uncropped photo
    /// from 0 to 1. `photoSize` is the photo as the camera oriented it, in pixels, so turns and
    /// sizes are true on a photo that isn't square. `snapsAngle` steps a radial turn by 15°.
    public func moved(_ part: MaskPart, from start: CGPoint, to end: CGPoint, photoSize: CGSize,
                      snapsAngle: Bool = false) -> Mask {
        var mask = self
        let shift = CGPoint(x: end.x - start.x, y: end.y - start.y)
        func shifted(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + shift.x, y: point.y + shift.y) }
        let long = max(photoSize.width, photoSize.height, 1)
        switch mask.shape {
        case var .linear(gradient):
            switch part {
            case .linearStart: gradient.start = shifted(gradient.start)
            case .linearEnd: gradient.end = shifted(gradient.end)
            case .linearTurn:
                // Both ends turn around the middle, in pixels with y down so the turn is true.
                let middle = CGPoint(x: (gradient.startX + gradient.endX) / 2, y: (gradient.startY + gradient.endY) / 2)
                let from = atan2((start.y - middle.y) * photoSize.height, (start.x - middle.x) * photoSize.width)
                let to = atan2((end.y - middle.y) * photoSize.height, (end.x - middle.x) * photoSize.width)
                let angle = to - from
                func turned(_ point: CGPoint) -> CGPoint {
                    let x = (point.x - middle.x) * photoSize.width, y = (point.y - middle.y) * photoSize.height
                    return CGPoint(x: middle.x + (x * cos(angle) - y * sin(angle)) / photoSize.width,
                                   y: middle.y + (x * sin(angle) + y * cos(angle)) / photoSize.height)
                }
                gradient.start = turned(gradient.start)
                gradient.end = turned(gradient.end)
            default:
                gradient.start = shifted(gradient.start)
                gradient.end = shifted(gradient.end)
            }
            mask.shape = .linear(gradient)
        case var .radial(gradient):
            // In pixels of the photo, y down, so the ellipse's axes are square to each other.
            let dx = (end.x - gradient.centerX) * photoSize.width, dy = (end.y - gradient.centerY) * photoSize.height
            let angle = gradient.angle * .pi / 180
            let range = RadialMask.radiusRange
            switch part {
            case .radialWidth:
                gradient.radiusX = min(max(abs(dx * cos(angle) + dy * sin(angle)) / long, range.lowerBound), range.upperBound)
            case .radialHeight:
                gradient.radiusY = min(max(abs(-dx * sin(angle) + dy * cos(angle)) / long, range.lowerBound), range.upperBound)
            case .radialTurn:
                // The handle sits above the center when the angle is 0.
                var degrees = atan2(dx, -dy) * 180 / .pi
                if snapsAngle { degrees = (degrees / 15).rounded() * 15 }
                gradient.angle = degrees
            default:
                gradient.center = shifted(gradient.center)
            }
            mask.shape = .radial(gradient)
        case var .brush(brush):
            // Only its pin moves a brush mask, and every stroke moves with it.
            guard case .pin = part else { break }
            for index in brush.strokes.indices {
                brush.strokes[index].points = brush.strokes[index].points.enumerated().map { offset, value in
                    value + (offset.isMultiple(of: 2) ? shift.x : shift.y)
                }
            }
            mask.shape = .brush(brush)
        case .subject, .unknown:
            break
        }
        return mask
    }
}
