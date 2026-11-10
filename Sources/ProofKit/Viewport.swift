import CoreGraphics

/// How far the photo in Edit is zoomed and which part of it is shown. Photo sizes are in the
/// cropped photo's full-resolution pixels; view sizes and points are in screen pixels, not points,
/// so a scale of 1 shows one photo pixel per screen pixel. Points are measured from the top left.
public struct Viewport: Equatable, Sendable {
    /// The fixed zoom steps after Fit, as in the View menu and the toolbar's pop-up.
    public static let steps: [Double] = [0.25, 0.5, 1, 2, 4]
    public static let maximumScale = 4.0
    public static let minimumScale = 0.25

    /// Screen pixels per photo pixel, or `nil` to fit the whole photo in the view.
    public var scale: Double?
    /// The photo point at the view's center, from 0 to 1 on each axis.
    public var center: CGPoint

    public init(scale: Double? = nil, center: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        self.scale = scale
        self.center = center
    }

    public var isFit: Bool { scale == nil }

    /// The scale that fits `photo` inside `view`.
    public static func fitScale(photo: CGSize, view: CGSize) -> Double {
        guard photo.width > 0, photo.height > 0, view.width > 0, view.height > 0 else { return 1 }
        return min(view.width / photo.width, view.height / photo.height)
    }

    /// The scale the photo is shown at, with Fit worked out for `view`.
    public func effectiveScale(photo: CGSize, view: CGSize) -> Double {
        scale ?? Self.fitScale(photo: photo, view: view)
    }

    // MARK: Steps

    /// Fit and the fixed steps in order of scale. Fit falls wherever it does for this photo and view,
    /// so a step smaller than Fit shows the photo smaller than the view.
    private static func stops(photo: CGSize, view: CGSize) -> [(scale: Double?, value: Double)] {
        ([(nil, fitScale(photo: photo, view: view))] + steps.map { ($0, $0) }).sorted { $0.value < $1.value }
    }

    /// The next stop larger than the current scale, keeping the same center. Unchanged at the largest.
    public func zoomedIn(photo: CGSize, view: CGSize) -> Viewport {
        let current = effectiveScale(photo: photo, view: view)
        guard let next = Self.stops(photo: photo, view: view).first(where: { $0.value > current * 1.001 }) else { return self }
        return Viewport(scale: next.scale, center: center).clamped(photo: photo, view: view)
    }

    /// The next stop smaller than the current scale, keeping the same center. Unchanged at the smallest.
    public func zoomedOut(photo: CGSize, view: CGSize) -> Viewport {
        let current = effectiveScale(photo: photo, view: view)
        guard let next = Self.stops(photo: photo, view: view).last(where: { $0.value < current / 1.001 }) else { return self }
        return Viewport(scale: next.scale, center: center).clamped(photo: photo, view: view)
    }

    public func canZoomIn(photo: CGSize, view: CGSize) -> Bool {
        zoomedIn(photo: photo, view: view) != self
    }

    public func canZoomOut(photo: CGSize, view: CGSize) -> Bool {
        zoomedOut(photo: photo, view: view) != self
    }

    // MARK: Placement

    /// Where the whole photo lies in the view, in view pixels. Its origin is in whole pixels, so at
    /// a scale of 1 each photo pixel lands on exactly one screen pixel.
    public func frame(photo: CGSize, view: CGSize) -> CGRect {
        let scale = effectiveScale(photo: photo, view: view)
        let size = CGSize(width: photo.width * scale, height: photo.height * scale)
        return CGRect(x: (view.width / 2 - center.x * size.width).rounded(),
                      y: (view.height / 2 - center.y * size.height).rounded(),
                      width: size.width, height: size.height)
    }

    /// The part of the photo the view shows, from 0 to 1 on each axis; empty if none.
    public func visibleRegion(photo: CGSize, view: CGSize) -> CGRect {
        let frame = frame(photo: photo, view: view)
        guard frame.width > 0, frame.height > 0 else { return .null }
        let shown = frame.intersection(CGRect(origin: .zero, size: view))
        guard !shown.isNull else { return .null }
        return CGRect(x: (shown.minX - frame.minX) / frame.width, y: (shown.minY - frame.minY) / frame.height,
                      width: shown.width / frame.width, height: shown.height / frame.height)
    }

    /// The photo point under `point` in the view, from 0 to 1 on each axis, or `nil` off the photo.
    public func photoPoint(at point: CGPoint, photo: CGSize, view: CGSize) -> CGPoint? {
        let frame = frame(photo: photo, view: view)
        guard frame.contains(point) else { return nil }
        return CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
    }

    // MARK: Changes

    /// Zoomed to `scale`, or to Fit if `nil`, keeping the photo point under `point` where it is,
    /// as far as the photo's edges allow. Free scales, from pinching, are kept within the steps' range.
    public func zoomed(to scale: Double?, keeping point: CGPoint, photo: CGSize, view: CGSize) -> Viewport {
        guard let scale else { return Viewport() }
        let newScale = min(max(scale, Self.minimumScale), Self.maximumScale)
        let frame = frame(photo: photo, view: view)
        guard frame.width > 0, frame.height > 0 else { return self }
        let anchor = CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
        let size = CGSize(width: photo.width * newScale, height: photo.height * newScale)
        let origin = CGPoint(x: point.x - anchor.x * size.width, y: point.y - anchor.y * size.height)
        let center = CGPoint(x: (view.width / 2 - origin.x) / size.width, y: (view.height / 2 - origin.y) / size.height)
        return Viewport(scale: newScale, center: center).clamped(photo: photo, view: view)
    }

    /// Moved so `point`, from 0 to 1 on each axis, is at the view's center, as far as the photo's
    /// edges allow. The navigator moves the view this way.
    public func centered(on point: CGPoint, photo: CGSize, view: CGSize) -> Viewport {
        guard let scale else { return self }
        return Viewport(scale: scale, center: point).clamped(photo: photo, view: view)
    }

    /// Moved so the photo follows a drag of `delta` view pixels, as far as its edges allow.
    public func panned(by delta: CGVector, photo: CGSize, view: CGSize) -> Viewport {
        let scale = effectiveScale(photo: photo, view: view)
        guard photo.width > 0, photo.height > 0 else { return self }
        var moved = self
        moved.center.x -= delta.dx / (photo.width * scale)
        moved.center.y -= delta.dy / (photo.height * scale)
        return moved.clamped(photo: photo, view: view)
    }

    /// Whether a drag would move the photo: it is larger than the view on at least one axis.
    public func canPan(photo: CGSize, view: CGSize) -> Bool {
        let scale = effectiveScale(photo: photo, view: view)
        return photo.width * scale > view.width + 0.5 || photo.height * scale > view.height + 0.5
    }

    /// Centered on each axis where the photo is smaller than the view; elsewhere moved so the
    /// photo covers the view, with no canvas showing past its edge.
    public func clamped(photo: CGSize, view: CGSize) -> Viewport {
        guard let scale, photo.width > 0, photo.height > 0 else { return Viewport(scale: scale) }
        func clamp(_ value: Double, photo: Double, view: Double) -> Double {
            let size = photo * scale
            guard size > view else { return 0.5 }
            let half = view / 2 / size
            return min(max(value, half), 1 - half)
        }
        return Viewport(scale: scale, center: CGPoint(x: clamp(center.x, photo: photo.width, view: view.width),
                                                      y: clamp(center.y, photo: photo.height, view: view.height)))
    }
}
