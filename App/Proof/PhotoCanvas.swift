import MetalKit
import OSLog
import ProofKit
import SwiftUI

/// Shows one RAW photo, fitted to the view, in a Metal-backed view.
struct PhotoCanvas: NSViewRepresentable {
    let url: URL
    let renderer: RAWRenderer
    /// In stops.
    var exposure: Double
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
        context.coordinator.show(url, exposure: exposure)
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
        var exposure: Double
    }

    private let renderer: RAWRenderer
    private let commandQueue: MTLCommandQueue?
    private var url: URL?
    private var size: CGSize = .zero
    private var exposure: Double = 0
    private var photo: RenderedPhoto?
    /// What `photo` was rendered from, or the request that failed, so it isn't retried.
    private var rendered: RenderRequest?
    private var isRendering = false
    private var resizeTask: Task<Void, Never>?

    private static let background = CIColor(red: 0.13, green: 0.13, blue: 0.13, colorSpace: RAWRenderer.colorSpace)!
    private static let log = Logger(subsystem: "Proof", category: "render")

    init(renderer: RAWRenderer) {
        self.renderer = renderer
        commandQueue = renderer.device.makeCommandQueue()
    }

    func show(_ url: URL, exposure: Double) {
        if url != self.url {
            self.url = url
            photo = nil
            view?.needsDisplay = true
        }
        if size == .zero { size = view?.drawableSize ?? .zero }
        self.exposure = exposure
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
            try renderer.draw(photo, into: drawable.texture, commandBuffer: commandBuffer, background: Self.background)
            commandBuffer.present(drawable)
            commandBuffer.commit()
        } catch {
            onError(error)
        }
    }

    private var latest: RenderRequest? {
        guard let url, size.width > 0, size.height > 0 else { return nil }
        return RenderRequest(url: url, size: size, exposure: exposure)
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
                let result = try await renderer.render(fitting: request.size, exposure: request.exposure)
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
