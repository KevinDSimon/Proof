import ProofKit
import ProofUI
import SwiftUI

/// Guided Upright's tool on the photo, for a finger or Apple Pencil: a drag draws a line along
/// something that should be upright or level, and the photo is corrected to it when the finger
/// lifts. Dragging a guide's end moves that end, dragging its line moves the whole guide, and a
/// tap on either selects the guide for the Transform card's Delete Guide. Two fingers pinch to
/// zoom and drag to pan, since one finger draws. A temporary tool, so it may sit on the photo.
struct GuideOverlay: View {
    let library: Library
    let zoom: CanvasZoom
    /// The correction the canvas shows.
    let transform: PerspectiveTransform
    /// The crop the canvas shows, which comes after the correction.
    let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space the correction works in.
    let photoSize: CGSize

    @State private var press = GuidePress()

    var body: some View {
        GeometryReader { geometry in
            let layout = GuideLayout(size: geometry.size, zoom: zoom, transform: transform, crop: crop, photoSize: photoSize)
            // Points from the drawable's pixels, which the zoom works in, to the tool's points.
            let pixelsPerPoint = zoom.viewSize.width / max(geometry.size.width, 1)
            ToolTouches { touch in
                switch touch {
                case let .moved(start, location):
                    press.moved(from: start, to: location, layout: layout)
                case let .ended(start, location):
                    press.ended(from: start, at: location, layout: layout, library: library)
                case .hover:
                    break
                case let .zoom(factor, center):
                    zoom.zoom(by: factor, keeping: CGPoint(x: center.x * pixelsPerPoint, y: center.y * pixelsPerPoint))
                case let .pan(delta):
                    zoom.pan(by: CGVector(dx: delta.dx * pixelsPerPoint, dy: delta.dy * pixelsPerPoint))
                case .zoomEnded:
                    zoom.settle()
                }
            }
            .overlay {
                GuideMarks(library: library, layout: layout, press: press)
                    .allowsHitTesting(false)
            }
            .accessibilityElement()
            .accessibilityLabel("Guides")
            .accessibilityValue("\(transform.guides.count) of \(Library.maximumGuides) drawn")
            .accessibilityHint("Drag along an edge that should be upright or level")
        }
    }
}
