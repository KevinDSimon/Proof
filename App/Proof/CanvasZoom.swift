import Foundation
import ProofKit

/// The zoom of the photo in Edit, shared by the canvas, the View menu and the toolbar's pop-up.
/// The math is `Viewport`'s; this holds the sizes it needs, which only the canvas knows.
@Observable @MainActor
final class CanvasZoom {
    private(set) var viewport = Viewport()
    /// The shown photo's size at full resolution and the canvas's size, both in pixels. The canvas
    /// sets them; until it has, the commands are disabled.
    var photoSize: CGSize = .zero
    var viewSize: CGSize = .zero
    /// Off while the crop tool is open, which always shows the whole photo.
    var isEnabled = true

    private var hasSizes: Bool {
        isEnabled && photoSize.width > 0 && viewSize.width > 0
    }

    var effectiveScale: Double {
        viewport.effectiveScale(photo: photoSize, view: viewSize)
    }

    /// "Fit", or the scale as a percentage, as the toolbar and VoiceOver show it.
    var title: String {
        guard let scale = viewport.scale else { return "Fit" }
        return Self.title(of: scale)
    }

    static func title(of scale: Double) -> String {
        scale.formatted(.percent.precision(.fractionLength(0)))
    }

    var canZoomIn: Bool { hasSizes && viewport.canZoomIn(photo: photoSize, view: viewSize) }
    var canZoomOut: Bool { hasSizes && viewport.canZoomOut(photo: photoSize, view: viewSize) }
    var canPan: Bool { hasSizes && viewport.canPan(photo: photoSize, view: viewSize) }

    func zoomIn() {
        guard hasSizes else { return }
        viewport = viewport.zoomedIn(photo: photoSize, view: viewSize)
    }

    func zoomOut() {
        guard hasSizes else { return }
        viewport = viewport.zoomedOut(photo: photoSize, view: viewSize)
    }

    /// Zooms to `scale`, or Fit if `nil`, around the view's center.
    func zoom(to scale: Double?) {
        guard hasSizes else { return }
        zoom(to: scale, keeping: CGPoint(x: viewSize.width / 2, y: viewSize.height / 2))
    }

    /// Zooms to `scale`, keeping the photo under `point`, in view pixels from the top left, in place.
    func zoom(to scale: Double?, keeping point: CGPoint) {
        guard hasSizes else { return }
        viewport = viewport.zoomed(to: scale, keeping: point, photo: photoSize, view: viewSize)
    }

    /// Zooms by `factor` from the current scale around `point`, for pinching and ⌘-scrolling.
    func zoom(by factor: Double, keeping point: CGPoint) {
        guard hasSizes else { return }
        zoom(to: effectiveScale * factor, keeping: point)
    }

    /// Double-click: from Fit to 100% at the clicked point, and from any other scale back to Fit.
    func toggle(at point: CGPoint) {
        guard hasSizes else { return }
        zoom(to: viewport.isFit ? 1 : nil, keeping: point)
    }

    func pan(by delta: CGVector) {
        guard hasSizes else { return }
        viewport = viewport.panned(by: delta, photo: photoSize, view: viewSize)
    }

    /// Back to Fit, for another photo or the crop tool.
    func reset() {
        viewport = Viewport()
    }

    /// Keeps the photo within its edges after the photo or the view changes size.
    func reclamp() {
        guard hasSizes else { return }
        let clamped = viewport.clamped(photo: photoSize, view: viewSize)
        if clamped != viewport { viewport = clamped }
    }
}
