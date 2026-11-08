import MetalKit
import ProofKit
import SwiftUI

/// Shows one RAW photo, fitted to the view, in a Metal-backed view.
struct PhotoCanvas: NSViewRepresentable {
    let url: URL
    let renderer: RAWRenderer
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
        context.coordinator.show(url)
    }
}

/// Keeps the main thread to drawing only: decoding and rendering at a new size happen in
/// `RAWRenderer`, and until a render finishes the previous one is scaled to the window.
@MainActor
final class PhotoCanvasCoordinator: NSObject, MTKViewDelegate {
    weak var view: MTKView?
    var onError: (Error) -> Void = { _ in }

    private let renderer: RAWRenderer
    private let commandQueue: MTLCommandQueue?
    private var url: URL?
    private var photo: RenderedPhoto?
    private var renderTask: Task<Void, Never>?

    private static let background = CIColor(red: 0.13, green: 0.13, blue: 0.13, colorSpace: RAWRenderer.colorSpace)!

    init(renderer: RAWRenderer) {
        self.renderer = renderer
        commandQueue = renderer.device.makeCommandQueue()
    }

    func show(_ url: URL) {
        guard url != self.url else { return }
        self.url = url
        photo = nil
        view?.needsDisplay = true
        requestRender(size: view?.drawableSize ?? .zero, delay: .zero)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Live resizing sends many sizes; render once it settles.
        requestRender(size: size, delay: .milliseconds(150))
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

    private func requestRender(size: CGSize, delay: Duration) {
        guard let url, size.width > 0, size.height > 0 else { return }
        renderTask?.cancel()
        renderTask = Task { [renderer] in
            do {
                try await Task.sleep(for: delay)
                try await renderer.open(url)
                try Task.checkCancellation()
                let rendered = try await renderer.render(fitting: size)
                try Task.checkCancellation()
                photo = rendered
                view?.needsDisplay = true
            } catch is CancellationError {
            } catch {
                onError(error)
            }
        }
    }
}
