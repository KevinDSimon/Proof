import MetalKit
import OSLog
import ProofKit
import SwiftUI

/// Shows one RAW photo in a Metal-backed view, fitted to the view or zoomed as `viewport` says.
struct PhotoCanvas: NSViewRepresentable {
    /// The neutral gray around the photo: white in the light appearance, 13% gray in the dark.
    /// Neutral grays match in Display P3 and sRGB, so the canvas and the SwiftUI backdrop around
    /// it meet without a seam.
    static func backdropGray(for colorScheme: ColorScheme) -> Double {
        colorScheme == .dark ? 0.13 : 1
    }

    let url: URL
    let renderer: RAWRenderer
    var recipe: EditRecipe
    /// The gray of the canvas around the photo, from 0 to 1.
    var backdropGray: Double
    /// Degrees clockwise to tilt the photo around its center as it is drawn. The crop tool
    /// straightens this way, without waiting for a render.
    var angle: Double = 0
    /// Read by the view that makes the canvas, so a change of zoom redraws it; `zoom` takes the
    /// canvas's gestures and sizes.
    var viewport: Viewport
    let zoom: CanvasZoom
    var onError: (Error) -> Void
    /// Receives the histogram of each render shown, with the photo it belongs to.
    var onHistogram: (Histogram, URL) -> Void = { _, _ in }

    func makeCoordinator() -> PhotoCanvasCoordinator {
        PhotoCanvasCoordinator(renderer: renderer, zoom: zoom)
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
        view.delegate = context.coordinator
        context.coordinator.view = view
        return view
    }

    func updateNSView(_ view: CanvasView, context: Context) {
        context.coordinator.onError = onError
        context.coordinator.onHistogram = onHistogram
        context.coordinator.setBackdrop(backdropGray)
        context.coordinator.setAngle(angle)
        context.coordinator.setViewport(viewport)
        context.coordinator.show(url, recipe: recipe)
    }
}

/// Turns pinches, scrolls, drags and double-clicks on the photo into zoom changes. Points are
/// passed on in drawable pixels from the top left, as `Viewport` measures them.
final class CanvasView: MTKView {
    weak var zoom: CanvasZoom?
    private var isDragging = false

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
        if zoom?.canPan == true { addCursorRect(bounds, cursor: .openHand) }
    }
}

/// Keeps the main thread to drawing only: decoding and rendering happen in `RAWRenderer`, and
/// until a render finishes the previous one is scaled to the window.
@MainActor
final class PhotoCanvasCoordinator: NSObject, MTKViewDelegate {
    weak var view: MTKView?
    var onError: (Error) -> Void = { _ in }
    var onHistogram: (Histogram, URL) -> Void = { _, _ in }

    private struct RenderRequest: Equatable {
        var url: URL
        var size: CGSize
        var recipe: EditRecipe
    }

    /// The part of the photo a zoomed view shows, at the view's scale up to full resolution.
    private struct DetailRequest: Equatable {
        var url: URL
        var recipe: EditRecipe
        var scale: Double
        var region: CGRect
    }

    private let renderer: RAWRenderer
    private let zoom: CanvasZoom
    private let commandQueue: MTLCommandQueue?
    private var url: URL?
    private var size: CGSize = .zero
    private var recipe = EditRecipe()
    private var photo: RenderedPhoto?
    /// What `photo` was rendered from, or the request that failed, so it isn't retried.
    private var rendered: RenderRequest?
    private var isRendering = false
    private var viewport = Viewport()
    /// The sharp part of a zoomed photo, drawn over `photo`, and what it was rendered from.
    private var detail: RenderedPhoto?
    private var renderedDetail: DetailRequest?
    /// The shown photo still to be measured for the histogram, and whether a measurement is running.
    private var unmeasured: (photo: RenderedPhoto, url: URL)?
    private var isMeasuring = false
    private var resizeTask: Task<Void, Never>?

    private var background = CIColor(red: 0, green: 0, blue: 0, colorSpace: RAWRenderer.colorSpace)!
    private var backdropGray: Double?
    private var angle = 0.0
    private static let log = Logger(subsystem: "Proof", category: "render")

    init(renderer: RAWRenderer, zoom: CanvasZoom) {
        self.renderer = renderer
        self.zoom = zoom
        commandQueue = renderer.device.makeCommandQueue()
    }

    func setBackdrop(_ gray: Double) {
        guard gray != backdropGray else { return }
        backdropGray = gray
        background = CIColor(red: gray, green: gray, blue: gray, colorSpace: RAWRenderer.colorSpace)!
        view?.needsDisplay = true
    }

    func setAngle(_ angle: Double) {
        guard angle != self.angle else { return }
        self.angle = angle
        view?.needsDisplay = true
    }

    func setViewport(_ viewport: Viewport) {
        guard viewport != self.viewport else { return }
        self.viewport = viewport
        view?.needsDisplay = true
        if let view { view.window?.invalidateCursorRects(for: view) }
        renderLatest()
    }

    func show(_ url: URL, recipe: EditRecipe) {
        if url != self.url {
            self.url = url
            photo = nil
            detail = nil
            renderedDetail = nil
            view?.needsDisplay = true
        }
        if size == .zero { size = view?.drawableSize ?? .zero }
        self.recipe = recipe
        renderLatest()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Live resizing sends many sizes; render once it settles.
        resizeTask?.cancel()
        resizeTask = Task {
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self.size = size
            zoom.viewSize = size
            zoom.reclamp()
            renderLatest()
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        do {
            let bounds = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let frame = viewport.isFit || photo == nil ? nil : viewport.frame(photo: photo!.photoSize, view: bounds)
            // A detail rendered before the crop changed would land in the wrong place.
            let detail = renderedDetail?.recipe.crop == rendered?.recipe.crop ? detail : nil
            try renderer.draw(photo, detail: frame == nil ? nil : detail, frame: frame, into: drawable.texture,
                              commandBuffer: commandBuffer, background: background, angle: angle)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        } catch {
            onError(error)
        }
    }

    private var latest: RenderRequest? {
        guard let url, size.width > 0, size.height > 0 else { return nil }
        return RenderRequest(url: url, size: size, recipe: recipe)
    }

    /// The region to render sharp while zoomed past the screen-size photo's own resolution, or
    /// the region already rendered while it still covers the view. The region reaches an eighth
    /// of the view past each edge, so a short pan doesn't need a new one.
    private var latestDetail: DetailRequest? {
        guard let url, let photo, let rendered, rendered.url == url, rendered.recipe.crop == recipe.crop,
              size.width > 0, photo.photoSize.width > 0 else { return nil }
        let scale = min(viewport.effectiveScale(photo: photo.photoSize, view: size), 1)
        let screenScale = Double(photo.texture.width) / photo.photoSize.width
        guard !viewport.isFit, scale > screenScale * 1.02 else { return nil }
        let visible = viewport.visibleRegion(photo: photo.photoSize, view: size)
        guard !visible.isNull else { return nil }
        if let renderedDetail, renderedDetail.url == url, renderedDetail.recipe == recipe,
           renderedDetail.scale == scale, renderedDetail.region.contains(visible) {
            return renderedDetail
        }
        let region = visible.insetBy(dx: -visible.width / 8, dy: -visible.height / 8)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        return DetailRequest(url: url, recipe: recipe, scale: scale, region: region)
    }

    /// Runs one render at a time. A render in flight is never discarded: while a slider is
    /// dragged faster than renders finish, each finished render is shown and the next one
    /// starts from the slider's latest value, skipping the values in between. While zoomed, the
    /// visible region renders before the screen-size photo, which then catches up for the
    /// histogram and for the edges a pan uncovers.
    private func renderLatest() {
        guard !isRendering else { return }
        if let request = latestDetail, request != renderedDetail {
            renderDetail(request)
            return
        }
        guard let request = latest, request != rendered else { return }
        isRendering = true
        Task { [renderer] in
            let start = ContinuousClock.now
            do {
                try await renderer.open(request.url)
                let lut = await LUTLibrary.shared.lut(for: request.recipe.look)
                let result = try await renderer.render(fitting: request.size, recipe: request.recipe, lut: lut)
                let ms = (ContinuousClock.now - start) / .milliseconds(1)
                Self.log.debug("Rendered \(result.texture.width)×\(result.texture.height) in \(ms, format: .fixed(precision: 1)) ms")
                if request.url == url {
                    photo = result
                    zoom.photoSize = result.photoSize
                    zoom.reclamp()
                    view?.needsDisplay = true
                    unmeasured = (result, request.url)
                    measureLatest()
                }
            } catch {
                onError(error)
            }
            rendered = request
            isRendering = false
            renderLatest()
        }
    }

    private func renderDetail(_ request: DetailRequest) {
        isRendering = true
        Task { [renderer] in
            let start = ContinuousClock.now
            do {
                try await renderer.open(request.url)
                let lut = await LUTLibrary.shared.lut(for: request.recipe.look)
                let result = try await renderer.render(region: request.region, scale: request.scale,
                                                       recipe: request.recipe, lut: lut)
                let ms = (ContinuousClock.now - start) / .milliseconds(1)
                Self.log.debug("Rendered region \(result.texture.width)×\(result.texture.height) in \(ms, format: .fixed(precision: 1)) ms")
                if request.url == url {
                    detail = result
                    view?.needsDisplay = true
                }
            } catch {
                onError(error)
            }
            renderedDetail = request
            isRendering = false
            renderLatest()
        }
    }

    /// Measures the histogram beside the render loop rather than in it, so a slider drag never
    /// waits for it. Like renders, one runs at a time and the next takes the latest photo shown.
    private func measureLatest() {
        guard !isMeasuring, let (photo, url) = unmeasured else { return }
        unmeasured = nil
        isMeasuring = true
        Task.detached { [renderer] in
            let histogram = try? renderer.histogram(of: photo)
            await MainActor.run {
                if let histogram, url == self.url { self.onHistogram(histogram, url) }
                self.isMeasuring = false
                self.measureLatest()
            }
        }
    }
}
