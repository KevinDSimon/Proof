import CoreGraphics
import Foundation
import ProofKit

/// The zoom of the photo in Edit, shared by the canvas, the View menu and the toolbar's pop-up.
/// The math is `Viewport`'s; this holds the sizes it needs, which only the canvas knows.
@Observable @MainActor
public final class CanvasZoom {
    public private(set) var viewport = Viewport()
    /// The shown photo's size at full resolution and the canvas's size, both in pixels. The canvas
    /// sets them; until it has, the commands are disabled.
    public var photoSize: CGSize = .zero
    public var viewSize: CGSize = .zero
    /// A small copy of the photo as shown, for the navigator. The canvas sets it after each render.
    public var preview: CGImage?
    /// What the canvas last drew: the screen-size photo and, while zoomed, its sharp region. The
    /// White Balance eyedropper's loupe reads its pixels from these.
    @ObservationIgnored public var shown: (photo: RenderedPhoto, detail: RenderedPhoto?)?
    /// Off while the crop tool is open, which always shows the whole photo.
    public var isEnabled = true
    /// A tool on the photo shows its own pointers, so the canvas doesn't show its open hand.
    public var hidesPanPointer = false

    private var hasSizes: Bool {
        isEnabled && photoSize.width > 0 && viewSize.width > 0
    }

    public var effectiveScale: Double {
        viewport.effectiveScale(photo: photoSize, view: viewSize)
    }

    /// "Fit", or the scale as a percentage, as the toolbar and VoiceOver show it.
    public var title: String {
        guard let scale = viewport.scale else { return "Fit" }
        return Self.title(of: scale)
    }

    public static func title(of scale: Double) -> String {
        scale.formatted(.percent.precision(.fractionLength(0)))
    }

    public var canZoomIn: Bool { hasSizes && viewport.canZoomIn(photo: photoSize, view: viewSize) }
    public var canZoomOut: Bool { hasSizes && viewport.canZoomOut(photo: photoSize, view: viewSize) }
    public var canPan: Bool { hasSizes && viewport.canPan(photo: photoSize, view: viewSize) }

    public func zoomIn() {
        guard hasSizes else { return }
        viewport = viewport.zoomedIn(photo: photoSize, view: viewSize)
    }

    public func zoomOut() {
        guard hasSizes else { return }
        viewport = viewport.zoomedOut(photo: photoSize, view: viewSize)
    }

    /// Zooms to `scale`, or Fit if `nil`, around the view's center.
    public func zoom(to scale: Double?) {
        guard hasSizes else { return }
        zoom(to: scale, keeping: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    /// Zooms to `scale`, keeping the photo under `point`, in view pixels from the top left, in place.
    public func zoom(to scale: Double?, keeping point: CGPoint) {
        guard hasSizes else { return }
        viewport = viewport.zoomed(to: scale, keeping: point, photo: photoSize, view: viewSize)
    }

    /// Zooms by `factor` from the current scale around `point`, for pinching and ⌘-scrolling.
    public func zoom(by factor: Double, keeping point: CGPoint) {
        guard hasSizes else { return }
        zoom(to: effectiveScale * factor, keeping: point)
    }

    /// Double-click: from Fit to 100% at the clicked point, and from any other scale back to Fit.
    public func toggle(at point: CGPoint) {
        guard hasSizes else { return }
        zoom(to: viewport.isFit ? 1 : nil, keeping: point)
    }

    /// Puts `point`, from 0 to 1 on each axis of the photo, at the view's center, for the navigator.
    public func center(on point: CGPoint) {
        guard hasSizes else { return }
        viewport = viewport.centered(on: point, photo: photoSize, view: viewSize)
    }

    /// The part of the photo in view, from 0 to 1 on each axis, for the navigator's box.
    public var visibleRegion: CGRect {
        guard hasSizes else { return .null }
        return viewport.visibleRegion(photo: photoSize, view: viewSize)
    }

    public func pan(by delta: CGVector) {
        guard hasSizes else { return }
        viewport = viewport.panned(by: delta, photo: photoSize, view: viewSize)
    }

    /// Back to Fit, for another photo or the crop tool.
    public func reset() {
        viewport = Viewport()
    }

    /// Keeps the photo within its edges after the photo or the view changes size.
    public func reclamp() {
        guard hasSizes else { return }
        let clamped = viewport.clamped(photo: photoSize, view: viewSize)
        if clamped != viewport { viewport = clamped }
    }
}
