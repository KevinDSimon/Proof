import CoreGraphics

/// Where the White Balance eyedropper's loupe sits, in points from the top left of the tool. With
/// a pointer it sits below and to the right, as in Lightroom; with a finger it sits centered above
/// the finger, where the hand doesn't cover it. Near an edge it moves to the other side, and it
/// stays within the tool.
public enum LoupePlacement: Sendable {
    case pointer
    case touch

    /// The space between the loupe and the point it shows, in points.
    public var gap: Double {
        switch self {
        case .pointer: 24
        case .touch: 44
        }
    }

    /// The loupe's center, for a loupe of `loupe` size showing `point`, in a tool of `size`.
    public func center(showing point: CGPoint, loupe: CGSize, in size: CGSize) -> CGPoint {
        let half = CGSize(width: loupe.width / 2, height: loupe.height / 2)
        var x: Double, y: Double
        switch self {
        case .pointer:
            x = point.x + gap + half.width
            y = point.y + gap + half.height
            if x + half.width > size.width { x = point.x - gap - half.width }
            if y + half.height > size.height { y = point.y - gap - half.height }
        case .touch:
            x = point.x
            y = point.y - gap - half.height
            // Below the finger only when there's no room above.
            if y - half.height < 0 { y = point.y + gap + half.height }
        }
        // Within the tool where it fits.
        x = min(max(x, half.width), max(size.width - half.width, half.width))
        return CGPoint(x: x, y: y)
    }
}
