import CoreGraphics

/// What part of a Guided Upright guide a press is on.
public enum GuidePart: Equatable, Sendable {
    case end(index: Int, isStart: Bool)
    case line(index: Int)

    public var index: Int {
        switch self {
        case let .end(index, _), let .line(index): index
        }
    }
}

/// How far the guide tool's guides reach for a press, in points: a finger's farther than a
/// pointer's, toward the 44-point targets of Apple's Human Interface Guidelines. Ends come before
/// lines, so a guide's end can be taken where it lies on another guide.
public enum GuideReach: Sendable {
    case pointer
    case touch

    /// How close a press must be to a guide's end to take the end.
    public var end: Double {
        switch self {
        case .pointer: 10
        case .touch: 22
        }
    }

    /// How close a press must be to a guide's line to take the line.
    public var line: Double {
        switch self {
        case .pointer: 6
        case .touch: 14
        }
    }

    /// The part of a guide at `point`, given each guide's ends on screen: the nearest end within
    /// reach, or else the nearest line within reach.
    public func part(at point: CGPoint, ends: [(CGPoint, CGPoint)]) -> GuidePart? {
        var bestEnd: (part: GuidePart, distance: Double)?
        var bestLine: (part: GuidePart, distance: Double)?
        for (index, guide) in ends.enumerated() {
            for (end, isStart) in [(guide.0, true), (guide.1, false)] {
                let distance = hypot(end.x - point.x, end.y - point.y)
                if distance <= self.end, distance < (bestEnd?.distance ?? .infinity) {
                    bestEnd = (.end(index: index, isStart: isStart), distance)
                }
            }
            let (a, b) = guide
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1) : 0
            let distance = hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
            if distance <= self.line, distance < (bestLine?.distance ?? .infinity) { bestLine = (.line(index: index), distance) }
        }
        return bestEnd?.part ?? bestLine?.part
    }
}
