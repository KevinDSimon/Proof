import MetalKit
import OSLog
import ProofKit
import SwiftUI

/// Shows one RAW photo, fitted to the view, in a Metal-backed view.
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
    var onError: (Error) -> Void

    func makeCoordinator() -> PhotoCanvasCoordinator {
        PhotoCanvasCoordinator(renderer: renderer)
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
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

    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.onError = onError
        context.coordinator.setBackdrop(backdropGray)
        context.coordinator.show(url, recipe: recipe)
    }
}

/// Keeps the main thread to drawing only: decoding and rendering happen in `RAWRenderer`, and
/// until a render finishes the previous one is scaled to the window.
@MainActor
final class PhotoCanvasCoordinator: NSObject, MTKViewDelegate {
    weak var view: MTKView?
    var onError: (Error) -> Void = { _ in }

    private struct RenderRequest: Equatable {
        var url: URL
        var size: CGSize
        var recipe: EditRecipe
    }

    private let renderer: RAWRenderer
    private let commandQueue: MTLCommandQueue?
    private var url: URL?
    private var size: CGSize = .zero
    private var recipe = EditRecipe()
    private var photo: RenderedPhoto?
    /// What `photo` was rendered from, or the request that failed, so it isn't retried.
    private var rendered: RenderRequest?
    private var isRendering = false
    private var resizeTask: Task<Void, Never>?

    private var background = CIColor(red: 0, green: 0, blue: 0, colorSpace: RAWRenderer.colorSpace)!
    private var backdropGray: Double?
    private static let log = Logger(subsystem: "Proof", category: "render")

    init(renderer: RAWRenderer) {
        self.renderer = renderer
        commandQueue = renderer.device.makeCommandQueue()
    }

    func setBackdrop(_ gray: Double) {
        guard gray != backdropGray else { return }
        backdropGray = gray
        background = CIColor(red: gray, green: gray, blue: gray, colorSpace: RAWRenderer.colorSpace)!
        view?.needsDisplay = true
    }

    func show(_ url: URL, recipe: EditRecipe) {
        if url != self.url {
            self.url = url
            photo = nil
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
            renderLatest()
        }
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        do {
            try renderer.draw(photo, into: drawable.texture, commandBuffer: commandBuffer, background: background)
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

    /// Runs one render at a time. A render in flight is never discarded: while a slider is
    /// dragged faster than renders finish, each finished render is shown and the next one
    /// starts from the slider's latest value, skipping the values in between.
    private func renderLatest() {
        guard !isRendering, let request = latest, request != rendered else { return }
        isRendering = true
        Task { [renderer] in
            let start = ContinuousClock.now
            do {
                try await renderer.open(request.url)
                let result = try await renderer.render(fitting: request.size, recipe: request.recipe)
                let ms = (ContinuousClock.now - start) / .milliseconds(1)
                Self.log.debug("Rendered \(result.texture.width)×\(result.texture.height) in \(ms, format: .fixed(precision: 1)) ms")
                if request.url == url {
                    photo = result
                    view?.needsDisplay = true
                }
            } catch {
                onError(error)
            }
            rendered = request
            isRendering = false
            renderLatest()
        }
    }
}
