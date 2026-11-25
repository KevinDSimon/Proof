import CoreGraphics

/// The size of a thumbnail cell in the grid, which a pinch changes. Limits keep at least a few
/// photos on screen at the largest size and the photos recognizable at the smallest.
public struct ThumbnailSize: Equatable, Sendable {
    public var range: ClosedRange<CGFloat>
    public var standard: CGFloat

    public init(range: ClosedRange<CGFloat>, standard: CGFloat) {
        self.range = range
        self.standard = standard
    }

    public static let mac = ThumbnailSize(range: 80...360, standard: 160)
    /// Three columns on the narrowest iPhone at the standard size, as in Photos.
    public static let touch = ThumbnailSize(range: 60...300, standard: 100)

    /// The size a pinch that started at `start` gives at `magnification`, within the limits.
    public func pinched(from start: CGFloat, by magnification: CGFloat) -> CGFloat {
        clamped(start * magnification)
    }

    /// `size` within the limits; a size that isn't a number gives the standard size.
    public func clamped(_ size: CGFloat) -> CGFloat {
        guard size.isFinite else { return standard }
        return min(max(size, range.lowerBound), range.upperBound)
    }
}
