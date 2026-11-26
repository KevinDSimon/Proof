import ProofKit
import ProofUI
import SwiftUI
import UIKit

/// The Spot Removal tool on the photo, for a finger or Apple Pencil: a tap covers the spot under
/// it, filled from a nearby area Proof chooses, and a drag paints a stroke over a longer mark,
/// such as a hair. A press on a spot, or on the selected spot's source, selects it and drags it.
/// Two fingers pinch to zoom and drag to pan, since one finger paints. A hovering Pencil, or the
/// pointer, shows the next spot's size. A temporary tool, so it may sit on the photo.
struct SpotOverlay: View {
    let library: Library
    let renderer: RAWRenderer
    let zoom: CanvasZoom
    /// The crop the canvas shows.
    let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space spots are placed in.
    let photoSize: CGSize

    @State private var hover: CGPoint?
    @State private var press = SpotPress()

    var body: some View {
        GeometryReader { geometry in
            let layout = SpotLayout(size: geometry.size, zoom: zoom, crop: crop, photoSize: photoSize)
            let spots = library.selectedEdit?.recipe.spots ?? []
            let selected = library.selectedSpot.flatMap { spots.indices.contains($0) ? $0 : nil }
            let hovered = hover.flatMap { layout.part(at: $0, spots: spots, selected: selected) }
            // Points from the drawable's pixels, which the zoom works in, to the tool's points.
            let pixelsPerPoint = zoom.viewSize.width / max(geometry.size.width, 1)
            ToolTouches { touch in
                switch touch {
                case let .moved(start, location):
                    press.moved(from: start, to: location, layout: layout, library: library)
                case let .ended(start, location):
                    press.ended(at: location, distance: hypot(location.x - start.x, location.y - start.y),
                                layout: layout, library: library, renderer: renderer)
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
                SpotMarks(library: library, layout: layout, brush: hovered == nil && !press.isActive ? hover : nil,
                          hovered: hovered, isPainting: press.painted != nil)
                    .allowsHitTesting(false)
            }
            .accessibilityElement()
            .accessibilityLabel("Photo")
            .accessibilityValue(spots.count == 1 ? "1 spot" : "\(spots.count) spots")
            .accessibilityHint("Tap a blemish to remove it, or drag over a longer one, such as a hair")
        }
    }
}
