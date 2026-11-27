import MetalKit
import ProofKit
import ProofUI
import SwiftUI

/// Shows one RAW photo in a Metal-backed view, fitted to the view or zoomed as `viewport` says.
struct PhotoCanvas: NSViewRepresentable {
    let url: URL
    let renderer: RAWRenderer
    var recipe: EditRecipe
    /// Changes when the LUT library does, so a look renamed or removed there renders again.
    var lutGeneration = 0
    /// The color of the canvas around the photo.
    var backdrop: CanvasColor
    /// Degrees clockwise to tilt the photo around its center as it is drawn. The crop tool
    /// straightens this way, without waiting for a render.
    var angle: Double = 0
    /// Read by the view that makes the canvas, so a change of zoom redraws it; `zoom` takes the
    /// canvas's gestures and sizes.
    var viewport: Viewport
    let zoom: CanvasZoom
    /// Where a newly opened photo's thumbnail is looked up, to show until its render is ready.
    let previews: ThumbnailCache
    var onError: (Error) -> Void
    /// Receives the histogram of each render shown, with the photo it belongs to.
    var onHistogram: (Histogram, URL) -> Void = { _, _ in }
    /// Told `true` while the photo has neither a render nor a preview to show, and `false` once
    /// it has one, so the view around the canvas can show that it is loading.
    var onWaiting: (Bool) -> Void = { _ in }

    func makeCoordinator() -> PhotoCanvasCoordinator {
        PhotoCanvasCoordinator(renderer: renderer, zoom: zoom, previews: previews)
    }

    func makeNSView(context: Context) -> CanvasView {
        let view = CanvasView(frame: .zero, device: renderer.device)
        view.zoom = zoom
        view.colorPixelFormat = RAWRenderer.pixelFormat
        view.colorspace = RAWRenderer.colorSpace
        // Core Image writes to the drawable from compute kernels.
        view.framebufferOnly = false
        // Draw only when there is something new, not every frame.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.coordinator = context.coordinator
        view.delegate = view
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        context.coordinator.onError = onError
        context.coordinator.onHistogram = onHistogram
        context.coordinator.onWaiting = onWaiting
        context.coordinator.setBackdrop(backdrop)
        context.coordinator.setAngle(angle)
        context.coordinator.setViewport(viewport)
        view.hidesPanPointer = zoom.hidesPanPointer
        context.coordinator.show(url, recipe: recipe, lutGeneration: lutGeneration)
    }
}

/// Turns pinches, scrolls, drags and double-clicks on the photo into zoom changes. Points are
/// passed on in drawable pixels from the top left, as `Viewport` measures them.
final class CanvasView: MTKView, MTKViewDelegate, CanvasSurface {
    weak var zoom: CanvasZoom?
    weak var coordinator: PhotoCanvasCoordinator?
    private var isDragging = false

    var hidesPanPointer = false {
        didSet { if hidesPanPointer != oldValue { zoomDidChange() } }
    }

    func setNeedsRedraw() { needsDisplay = true }

    func zoomDidChange() { window?.invalidateCursorRects(for: self) }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        coordinator?.drawableSizeWillChange(size)
    }

    func draw(in view: MTKView) { coordinator?.draw(currentDrawable) }

    private var pixelsPerPoint: CGFloat {
        bounds.width > 0 ? drawableSize.width / bounds.width : 1
    }

    private func pixelPoint(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        return CGPoint(x: point.x * pixelsPerPoint, y: (bounds.height - point.y) * pixelsPerPoint)
    }

    override func magnify(with event: NSEvent) {
        guard let zoom, zoom.isEnabled else { return super.magnify(with: event) }
        zoom.zoom(by: 1 + event.magnification, keeping: pixelPoint(of: event))
    }

    /// ⌘-scroll zooms around the pointer; scrolling pans while the photo is larger than the view.
    override func scrollWheel(with event: NSEvent) {
        guard let zoom, zoom.isEnabled else { return super.scrollWheel(with: event) }
        // A mouse wheel reports lines rather than points.
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        if event.modifierFlags.contains(.command) {
            let delta = event.scrollingDeltaY * step
            zoom.zoom(by: exp(delta * 0.01), keeping: pixelPoint(of: event))
        } else if zoom.canPan {
            zoom.pan(by: CGVector(dx: event.scrollingDeltaX * step * pixelsPerPoint,
                                  dy: event.scrollingDeltaY * step * pixelsPerPoint))
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let zoom, zoom.isEnabled else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            zoom.toggle(at: pixelPoint(of: event))
        } else if zoom.canPan {
            isDragging = true
            NSCursor.closedHand.set()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging, let zoom else { return super.mouseDragged(with: event) }
        // `deltaY` already points down, as the view's pixels are measured.
        zoom.pan(by: CGVector(dx: event.deltaX * pixelsPerPoint, dy: event.deltaY * pixelsPerPoint))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return super.mouseUp(with: event) }
        isDragging = false
        window?.invalidateCursorRects(for: self)
    }

    /// An open hand while there is somewhere to pan to.
    override func resetCursorRects() {
        if zoom?.canPan == true, !hidesPanPointer { addCursorRect(bounds, cursor: .openHand) }
    }
}

