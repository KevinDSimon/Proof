import MetalKit
import ProofKit
import ProofUI
import SwiftUI
import UIKit

/// Shows one RAW photo in a Metal-backed view, fitted to the view or zoomed as `viewport` says.
/// The render loop is the Mac's (`PhotoCanvasCoordinator`); this adds the touch gestures.
struct PhotoCanvas: UIViewRepresentable {
    let url: URL
    let renderer: RAWRenderer
    var recipe: EditRecipe
    /// The color of the canvas around the photo.
    var backdrop: CanvasColor
    /// Read by the view that makes the canvas, so a change of zoom redraws it; `zoom` takes the
    /// canvas's gestures and sizes.
    var viewport: Viewport
    let zoom: CanvasZoom
    /// Where a newly opened photo's thumbnail is looked up, to show until its render is ready.
    let previews: ThumbnailCache
    let actions: PhotoCanvasActions
    var onError: (Error) -> Void
    /// Told `true` while the photo has neither a render nor a preview to show, and `false` once
    /// it has one, so the view around the canvas can show that it is loading.
    /// Receives the histogram of each render shown, with the photo it belongs to.
    var onHistogram: (Histogram, URL) -> Void = { _, _ in }
    var onWaiting: (Bool) -> Void = { _ in }

    func makeCoordinator() -> PhotoCanvasCoordinator {
        PhotoCanvasCoordinator(renderer: renderer, zoom: zoom, previews: previews)
    }

    func makeUIView(context: Context) -> CanvasView {
        let view = CanvasView(frame: .zero, device: renderer.device)
        view.zoom = zoom
        view.colorPixelFormat = RAWRenderer.pixelFormat
        (view.layer as? CAMetalLayer)?.colorspace = RAWRenderer.colorSpace
        // Core Image writes to the drawable from compute kernels.
        view.framebufferOnly = false
        // Draw only when there is something new, not every frame.
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.isOpaque = true
        view.coordinator = context.coordinator
        view.delegate = view
        context.coordinator.view = view
        return view
    }

    func updateUIView(_ view: CanvasView, context: Context) {
        view.actions = actions
        context.coordinator.onError = onError
        context.coordinator.onHistogram = onHistogram
        context.coordinator.onWaiting = onWaiting
        context.coordinator.setBackdrop(backdrop)
        context.coordinator.setViewport(viewport)
        context.coordinator.show(url, recipe: recipe)
    }
}

/// What the canvas's gestures do beyond zooming and panning, which `CanvasZoom` handles.
struct PhotoCanvasActions {
    /// Whether a sideways swipe moves to another photo: only at Fit, with no tool open.
    var canSwipe: Bool
    /// `true` while a finger is held on the photo, to show the original, and `false` once it lifts.
    var showOriginal: (Bool) -> Void
    /// A swipe to the left shows the next photo; one to the right, the previous one.
    var swipe: (UISwipeGestureRecognizer.Direction) -> Void
}

/// Turns pinches, drags, double-taps, touches and holds, and swipes on the photo into zoom
/// changes and actions. Points are passed on in drawable pixels from the top left, as
/// `Viewport` measures them.
final class CanvasView: MTKView, MTKViewDelegate, CanvasSurface, UIGestureRecognizerDelegate {
    weak var zoom: CanvasZoom?
    weak var coordinator: PhotoCanvasCoordinator?
    var actions = PhotoCanvasActions(canSwipe: false, showOriginal: { _ in }, swipe: { _ in })

    private let pinch = UIPinchGestureRecognizer()
    private let pan = UIPanGestureRecognizer()
    private let doubleTap = UITapGestureRecognizer()
    private let hold = UILongPressGestureRecognizer()
    private let swipeLeft = UISwipeGestureRecognizer()
    private let swipeRight = UISwipeGestureRecognizer()
    /// The pinch's center when last seen, so moving the fingers pans as they zoom, as in Photos.
    private var pinchCenter: CGPoint?

    override init(frame: CGRect, device: MTLDevice?) {
        super.init(frame: frame, device: device)
        pinch.addTarget(self, action: #selector(pinched))
        pan.addTarget(self, action: #selector(panned))
        pan.maximumNumberOfTouches = 2
        doubleTap.numberOfTapsRequired = 2
        doubleTap.addTarget(self, action: #selector(doubleTapped))
        hold.minimumPressDuration = 0.3
        hold.addTarget(self, action: #selector(held))
        swipeLeft.direction = .left
        swipeRight.direction = .right
        for swipe in [swipeLeft, swipeRight] {
            swipe.addTarget(self, action: #selector(swiped))
        }
        for recognizer in [pinch, pan, doubleTap, hold, swipeLeft, swipeRight] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // At the screen's own scale, so 100% puts one photo pixel on one screen pixel.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.windowScene?.screen { contentScaleFactor = screen.nativeScale }
    }

    func setNeedsRedraw() { setNeedsDisplay() }

    func zoomDidChange() {}

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        coordinator?.drawableSizeWillChange(size)
    }

    func draw(in view: MTKView) { coordinator?.draw(currentDrawable) }

    private var pixelsPerPoint: CGFloat {
        bounds.width > 0 ? drawableSize.width / bounds.width : 1
    }

    private func pixels(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x * pixelsPerPoint, y: point.y * pixelsPerPoint)
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        guard let zoom else { return }
        let center = pixels(pinch.location(in: self))
        switch pinch.state {
        case .began:
            pinchCenter = center
        case .changed:
            if let last = pinchCenter {
                zoom.pan(by: CGVector(dx: center.x - last.x, dy: center.y - last.y))
            }
            zoom.zoom(by: pinch.scale, keeping: center)
            pinch.scale = 1
            pinchCenter = center
        default:
            pinchCenter = nil
            zoom.settle()
        }
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        guard let zoom, pinchCenter == nil else { return }
        let moved = pixels(pan.translation(in: self))
        zoom.pan(by: CGVector(dx: moved.x, dy: moved.y))
        pan.setTranslation(.zero, in: self)
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        zoom?.toggle(at: pixels(tap.location(in: self)))
    }

    @objc private func held(_ hold: UILongPressGestureRecognizer) {
        switch hold.state {
        case .began: actions.showOriginal(true)
        case .ended, .cancelled, .failed: actions.showOriginal(false)
        default: break
        }
    }

    @objc private func swiped(_ swipe: UISwipeGestureRecognizer) {
        actions.swipe(swipe.direction)
    }

    // UIView's own check, which is also the delegate's.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let zoom, zoom.isEnabled else { return false }
        switch recognizer {
        case pan: return zoom.canPan
        case swipeLeft, swipeRight: return actions.canSwipe && zoom.viewport.isFit
        default: return super.gestureRecognizerShouldBegin(recognizer)
        }
    }

    // Pinching and panning together zoom and move the photo at once.
    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (recognizer === pinch && other === pan) || (recognizer === pan && other === pinch)
    }
}
