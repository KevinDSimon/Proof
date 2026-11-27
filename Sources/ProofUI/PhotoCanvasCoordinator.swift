import CoreGraphics
import CoreImage
import Metal
import OSLog
import ProofKit
import QuartzCore
import SwiftUI

/// The Metal view a `PhotoCanvasCoordinator` draws into. Each app's canvas view conforms, so the
/// render loop is shared while pointer, touch and cursor handling stay in the app.
@MainActor
public protocol CanvasSurface: AnyObject {
    var drawableSize: CGSize { get }
    func setNeedsRedraw()
    /// The zoom changed; the Mac updates its open-hand pointer.
    func zoomDidChange()
}

/// Keeps the main thread to drawing only: decoding and rendering happen in `RAWRenderer`, and
/// until a render finishes the previous one is scaled to the window.
@MainActor
public final class PhotoCanvasCoordinator {
    public weak var view: CanvasSurface?
    public var onError: (Error) -> Void = { _ in }
    public var onHistogram: (Histogram, URL) -> Void = { _, _ in }
    public var onWaiting: (Bool) -> Void = { _ in }

    private struct RenderRequest: Equatable {
        var url: URL
        var size: CGSize
        var recipe: EditRecipe
        var lutGeneration: Int
    }

    /// The part of the photo a zoomed view shows, at the view's scale up to full resolution.
    private struct DetailRequest: Equatable {
        var url: URL
        var recipe: EditRecipe
        var lutGeneration: Int
        var scale: Double
        var region: CGRect
    }

    private let renderer: RAWRenderer
    private let zoom: CanvasZoom
    private let previews: ThumbnailCache
    private let commandQueue: MTLCommandQueue?
    private var url: URL?
    private var size: CGSize = .zero
    private var recipe = EditRecipe()
    private var lutGeneration = 0
    private var photo: RenderedPhoto?
    /// What `photo` was rendered from, or the request that failed, so it isn't retried.
    private var rendered: RenderRequest?
    private var isRendering = false
    private var viewport = Viewport()
    /// The sharp part of a zoomed photo, drawn over `photo`, and what it was rendered from.
    private var detail: RenderedPhoto?
    private var renderedDetail: DetailRequest?
    /// The photo's thumbnail, shown fitted to the view until its first render is ready.
    private var preview: RenderedPhoto?
    private var previewTask: Task<Void, Never>?
    /// The shown photo still to be measured for the histogram, and whether a measurement is running.
    private var unmeasured: (photo: RenderedPhoto, url: URL)?
    private var isMeasuring = false
    private var resizeTask: Task<Void, Never>?
    /// How much memory zoomed renders may use, read when a photo opens and after a memory
    /// warning, not on every request, so that the scale it allows stays put while zoomed.
    private var budget = RenderBudget.current()

    private var background = CIColor(red: 0, green: 0, blue: 0, colorSpace: RAWRenderer.colorSpace)!
    private var backdrop: CanvasColor?
    private var angle = 0.0
    private static let log = Logger(subsystem: "Proof", category: "render")

    public init(renderer: RAWRenderer, zoom: CanvasZoom, previews: ThumbnailCache) {
        self.renderer = renderer
        self.zoom = zoom
        self.previews = previews
        commandQueue = renderer.device.makeCommandQueue()
    }

    public func setBackdrop(_ backdrop: CanvasColor) {
        guard backdrop != self.backdrop else { return }
        self.backdrop = backdrop
        let color = backdrop.components
        background = CIColor(red: color.red, green: color.green, blue: color.blue, colorSpace: RAWRenderer.colorSpace)!
        view?.setNeedsRedraw()
    }

    public func setAngle(_ angle: Double) {
        guard angle != self.angle else { return }
        self.angle = angle
        view?.setNeedsRedraw()
    }

    public func setViewport(_ viewport: Viewport) {
        guard viewport != self.viewport else { return }
        self.viewport = viewport
        view?.setNeedsRedraw()
        view?.zoomDidChange()
        renderLatest()
    }

    /// Renders `url` with `recipe`, again when `lutGeneration` changes, since the LUT the look
    /// names may have been renamed or removed.
    public func show(_ url: URL, recipe: EditRecipe, lutGeneration: Int = 0) {
        if url != self.url {
            self.url = url
            budget = .current()
            photo = nil
            detail = nil
            renderedDetail = nil
            preview = nil
            view?.setNeedsRedraw()
            loadPreview(of: url, recipe: recipe)
        }
        if size == .zero { size = view?.drawableSize ?? .zero }
        self.recipe = recipe
        self.lutGeneration = lutGeneration
        renderLatest()
    }

    /// Shows the photo's cached thumbnail with `recipe`, the one the grid and filmstrip show,
    /// until the render is ready: a thumbnail of the edit has its crop and colors, so the render
    /// that replaces it only sharpens it. It is fitted to the cropped photo's size, read from the
    /// file, which is the frame the render fills. Without a cached thumbnail, the canvas waits.
    private func loadPreview(of url: URL, recipe: EditRecipe) {
        previewTask?.cancel()
        previewTask = Task { [renderer, previews] in
            onWaiting(false)
            let preview = await Task.detached(priority: .userInitiated) { () -> RenderedPhoto? in
                guard let image = previews.cachedThumbnail(for: url, edit: recipe),
                      !Task.isCancelled,
                      let size = RAWRenderer.photoSize(of: url, crop: recipe.crop, profile: recipe.profile) else { return nil }
                return try? renderer.placeholder(image, photoSize: size)
            }.value
            guard !Task.isCancelled, url == self.url, photo == nil else { return }
            if let preview {
                self.preview = preview
                // The preview has the render's frame, so zooming can start before the render is ready.
                zoom.photoSize = preview.photoSize
                zoom.reclamp()
                view?.setNeedsRedraw()
            } else {
                onWaiting(true)
            }
        }
    }

    /// Frees what the renderer keeps of the open photo and reads the memory budget again. iPad
    /// and iPhone call it when the system warns that memory is low and when the app goes to the
    /// background, where iOS ends the apps using the most memory first (#236). The photo stays
    /// on screen, with the zoomed region already rendered, which is only the view's size; the
    /// next render decodes the photo again.
    public func releaseMemory() {
        budget = .current()
        Task { [renderer] in await renderer.clearCaches() }
    }

    public func drawableSizeWillChange(_ size: CGSize) {
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

    public func draw(_ drawable: CAMetalDrawable?) {
        guard let drawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        do {
            let bounds = CGSize(width: drawable.texture.width, height: drawable.texture.height)
            let shown = photo ?? preview
            let frame = viewport.isFit || shown == nil ? nil : viewport.frame(photo: shown!.photoSize, view: bounds)
            // A detail rendered before the crop changed would land in the wrong place.
            let detail = renderedDetail?.recipe.crop == rendered?.recipe.crop ? detail : nil
            zoom.shown = photo.map { ($0, frame == nil ? nil : detail) }
            try renderer.draw(shown, detail: frame == nil ? nil : detail, frame: frame, into: drawable.texture,
                              commandBuffer: commandBuffer, background: background, angle: angle)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        } catch {
            onError(error)
        }
    }

    private var latest: RenderRequest? {
        guard let url, size.width > 0, size.height > 0 else { return nil }
        return RenderRequest(url: url, size: size, recipe: recipe, lutGeneration: lutGeneration)
    }

    /// The region to render sharp while zoomed past the screen-size photo's own resolution, or
    /// the region already rendered while it still covers the view. The region reaches an eighth
    /// of the view past each edge, so a short pan doesn't need a new one.
    private var latestDetail: DetailRequest? {
        guard let url, let photo, let rendered, rendered.url == url, rendered.recipe.crop == recipe.crop,
              size.width > 0, photo.photoSize.width > 0 else { return nil }
        // On iPhone and iPad, at most the scale whose whole-photo decode fits the memory budget;
        // past it the region is enlarged (decision 0053).
        let scale = min(viewport.effectiveScale(photo: photo.photoSize, view: size), budget.maxScale(photoSize: photo.photoSize))
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
        return DetailRequest(url: url, recipe: recipe, lutGeneration: lutGeneration, scale: scale, region: region)
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
                // A render can't be stopped once it starts, so one for a photo stepped past is
                // dropped before it opens the file and again before it renders.
                guard request.url == url else { throw CancellationError() }
                try await renderer.open(request.url)
                let lut = await LUTLibrary.shared.lut(for: request.recipe.look)
                guard request.url == url else { throw CancellationError() }
                let result = try await renderer.render(fitting: request.size, recipe: request.recipe, lut: lut)
                let ms = (ContinuousClock.now - start) / .milliseconds(1)
                Self.log.debug("Rendered \(result.texture.width)×\(result.texture.height) in \(ms, format: .fixed(precision: 1)) ms")
                if request.url == url {
                    photo = result
                    preview = nil
                    previewTask?.cancel()
                    onWaiting(false)
                    zoom.photoSize = result.photoSize
                    zoom.reclamp()
                    view?.setNeedsRedraw()
                    unmeasured = (result, request.url)
                    measureLatest()
                }
            } catch is CancellationError {
            } catch {
                if request.url == url {
                    onWaiting(false)
                    onError(error)
                }
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
                guard request.url == url else { throw CancellationError() }
                try await renderer.open(request.url)
                let lut = await LUTLibrary.shared.lut(for: request.recipe.look)
                guard request.url == url else { throw CancellationError() }
                let result = try await renderer.render(region: request.region, scale: request.scale,
                                                       recipe: request.recipe, lut: lut)
                let ms = (ContinuousClock.now - start) / .milliseconds(1)
                Self.log.debug("Rendered region \(result.texture.width)×\(result.texture.height) in \(ms, format: .fixed(precision: 1)) ms")
                if request.url == url {
                    detail = result
                    view?.setNeedsRedraw()
                }
            } catch is CancellationError {
            } catch {
                if request.url == url { onError(error) }
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
            let preview = try? renderer.preview(of: photo, maxPixelSize: 480)
            await MainActor.run {
                if let histogram, url == self.url { self.onHistogram(histogram, url) }
                if let preview, url == self.url { self.zoom.preview = preview }
                self.isMeasuring = false
                self.measureLatest()
            }
        }
    }
}

public extension CanvasColor {
    /// In Display P3, as the Metal canvas draws it, so the SwiftUI backdrop around it meets it
    /// without a seam.
    var color: Color {
        let color = components
        return Color(.displayP3, red: color.red, green: color.green, blue: color.blue)
    }
}
