import ProofKit
import ProofUI
import SwiftUI
import UIKit

/// The Masks tool on the photo, for a finger or Apple Pencil. Every mask shows a pin: tap one to
/// select its mask, and drag a gradient's or brush mask's pin to move it. The selected linear
/// gradient's middle line turns it and its outer lines change the fade; the selected radial
/// gradient moves from inside its ellipse, sizes from the handles on its sides and turns from the
/// one above it. On a selected brush mask, a finger or the Pencil paints, or erases with Erase
/// chosen, without pressure. Two fingers pinch to zoom and drag to pan, since one finger paints.
/// A hovering Pencil, or the pointer, shows the brush's size. A temporary tool, so it may sit on
/// the photo.
struct MaskOverlay: View {
    let library: Library
    let zoom: CanvasZoom
    /// The crop the canvas shows.
    let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space masks are placed in.
    let photoSize: CGSize

    @State private var hover: CGPoint?
    @State private var press = MaskPress()

    var body: some View {
        GeometryReader { geometry in
            let layout = MaskLayout(size: geometry.size, zoom: zoom, crop: crop, photoSize: photoSize)
            let layers = library.layers
            let paints = MaskPress.paints(library)
            let hovered = hover.flatMap { layout.part(at: $0, library: library) }
            // Points from the drawable's pixels, which the zoom works in, to the tool's points.
            let pixelsPerPoint = zoom.viewSize.width / max(geometry.size.width, 1)
            ToolTouches { touch in
                switch touch {
                case let .moved(start, location):
                    press.moved(from: start, to: location, layout: layout, library: library)
                case let .ended(_, location):
                    press.ended(at: location, layout: layout, library: library)
                case let .hover(location):
                    hover = location
                case let .zoom(factor, center):
                    zoom.zoom(by: factor, keeping: CGPoint(x: center.x * pixelsPerPoint, y: center.y * pixelsPerPoint))
                case let .pan(delta):
                    zoom.pan(by: CGVector(dx: delta.dx * pixelsPerPoint, dy: delta.dy * pixelsPerPoint))
                case .zoomEnded:
                    zoom.settle()
                }
            }
            .overlay {
                MaskMarks(library: library, layout: layout, brush: paints && hovered == nil && !press.isActive ? hover : nil)
                    .allowsHitTesting(false)
            }
            .accessibilityElement()
            .accessibilityLabel("Photo")
            .accessibilityValue(layers.count == 1 ? "1 mask" : "\(layers.count) masks")
            .accessibilityHint(paints ? "Drag to paint the mask" : "Drag a mask's pin to move it")
        }
    }
}
