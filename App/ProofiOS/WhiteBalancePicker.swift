import ProofKit
import ProofUI
import SwiftUI

/// The White Balance eyedropper over the photo while it is open, for a finger or Apple Pencil: a
/// touch shows a loupe above the finger of the pixels under it, with the center one's RGB values,
/// and lifting sets the white balance that makes that spot neutral gray. A tap picks at once, and
/// sliding before lifting finds the spot in the loupe. A hovering Pencil, or the pointer, shows
/// the loupe too. Two fingers pinch to zoom and drag to pan, so a small gray area can be picked at
/// any scale. A temporary tool, so it may sit on the photo.
struct WhiteBalancePicker: View {
    let library: Library
    let renderer: RAWRenderer

    /// The finger, Pencil or pointer, in points from the top left, and the loupe's pixels under it.
    @State private var touch: CGPoint?
    @State private var loupe: CGImage?

    /// The ring that marks the measured point around the finger, in points.
    private static let ringRadius = 14.0

    var body: some View {
        GeometryReader { proxy in
            let sampler = WhiteBalanceSampler(library: library, renderer: renderer, size: proxy.size)
            let pixelsPerPoint = library.zoom.viewSize.width / max(proxy.size.width, 1)
            ToolTouches { event in
                switch event {
                case let .moved(_, location):
                    show(at: location, sampler: sampler)
                case let .ended(_, location):
                    touch = nil
                    loupe = nil
                    sampler.pick(at: location)
                case let .hover(location):
                    if let location { show(at: location, sampler: sampler) } else { touch = nil; loupe = nil }
                case let .zoom(factor, center):
                    touch = nil
                    library.zoom.zoom(by: factor, keeping: CGPoint(x: center.x * pixelsPerPoint, y: center.y * pixelsPerPoint))
                case let .pan(delta):
                    library.zoom.pan(by: CGVector(dx: delta.dx * pixelsPerPoint, dy: delta.dy * pixelsPerPoint))
                case .zoomEnded:
                    library.zoom.settle()
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Photo")
            .accessibilityHint("Tap something neutral gray to set the white balance")
            if let touch {
                // The point measured, which the finger covers, marked around its edge.
                Circle()
                    .strokeBorder(.white, lineWidth: 1.5)
                    .shadow(color: .black.opacity(0.6), radius: 1.5)
                    .frame(width: Self.ringRadius * 2, height: Self.ringRadius * 2)
                    .position(touch)
                    .allowsHitTesting(false)
                if let loupe {
                    LoupeView(pixels: loupe, isMeasuring: library.isAutoAdjusting)
                        .fixedSize()
                        .position(LoupePlacement.touch.center(showing: touch, loupe: LoupeView.size, in: proxy.size))
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private func show(at location: CGPoint, sampler: WhiteBalanceSampler) {
        touch = location
        loupe = sampler.pixels(at: location)
    }
}
