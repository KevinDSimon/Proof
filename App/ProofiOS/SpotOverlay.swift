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
            SpotTouches { touch in
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

/// What a touch on the Spot Removal tool does, in the tool's points.
private enum SpotTouch {
    /// One finger or the Pencil, which landed at the first point, is at the second.
    case moved(CGPoint, CGPoint)
    /// One finger or the Pencil, which landed at the first point, lifted at the second.
    case ended(CGPoint, CGPoint)
    /// A hovering Pencil or the pointer is here, or `nil` once it leaves.
    case hover(CGPoint?)
    /// Two fingers pinched by this factor around this point.
    case zoom(Double, CGPoint)
    /// Two fingers moved by this much.
    case pan(CGVector)
    case zoomEnded
}

/// UIKit's recognizers, which count fingers, where SwiftUI's drag doesn't: one finger or the
/// Pencil places, paints and moves spots, and two zoom and pan.
private struct SpotTouches: UIViewRepresentable {
    let onTouch: (SpotTouch) -> Void

    func makeUIView(context: Context) -> SpotTouchView { SpotTouchView() }

    func updateUIView(_ view: SpotTouchView, context: Context) {
        view.onTouch = onTouch
    }
}

private final class SpotTouchView: UIView, UIGestureRecognizerDelegate {
    var onTouch: (SpotTouch) -> Void = { _ in }

    private let tap = UITapGestureRecognizer()
    private let drag = UIPanGestureRecognizer()
    private let pinch = UIPinchGestureRecognizer()
    private let twoFingerPan = UIPanGestureRecognizer()
    private let hover = UIHoverGestureRecognizer()
    /// Where the drag landed.
    private var dragStart: CGPoint?
    /// The pinch's center when last seen, so moving the fingers pans as they zoom, as in Photos.
    private var pinchCenter: CGPoint?

    init() {
        super.init(frame: .zero)
        backgroundColor = .clear
        tap.addTarget(self, action: #selector(tapped))
        drag.maximumNumberOfTouches = 1
        drag.addTarget(self, action: #selector(dragged))
        pinch.addTarget(self, action: #selector(pinched))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.addTarget(self, action: #selector(twoFingerPanned))
        hover.addTarget(self, action: #selector(hovered))
        for recognizer in [tap, drag, pinch, twoFingerPan, hover] {
            recognizer.delegate = self
            addGestureRecognizer(recognizer)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        let location = tap.location(in: self)
        onTouch(.moved(location, location))
        onTouch(.ended(location, location))
    }

    @objc private func dragged(_ drag: UIPanGestureRecognizer) {
        let location = drag.location(in: self)
        switch drag.state {
        case .began:
            // The drag begins once the touch has moved a little, so it landed back where it started.
            let moved = drag.translation(in: self)
            let start = CGPoint(x: location.x - moved.x, y: location.y - moved.y)
            dragStart = start
            onTouch(.moved(start, location))
        case .changed:
            if let dragStart { onTouch(.moved(dragStart, location)) }
        default:
            if let dragStart { onTouch(.ended(dragStart, location)) }
            dragStart = nil
        }
    }

    @objc private func pinched(_ pinch: UIPinchGestureRecognizer) {
        let center = pinch.location(in: self)
        switch pinch.state {
        case .began:
            pinchCenter = center
        case .changed:
            if let last = pinchCenter { onTouch(.pan(CGVector(dx: center.x - last.x, dy: center.y - last.y))) }
            onTouch(.zoom(pinch.scale, center))
            pinch.scale = 1
            pinchCenter = center
        default:
            pinchCenter = nil
            onTouch(.zoomEnded)
        }
    }

    @objc private func twoFingerPanned(_ pan: UIPanGestureRecognizer) {
        guard pinchCenter == nil else { return }
        let moved = pan.translation(in: self)
        onTouch(.pan(CGVector(dx: moved.x, dy: moved.y)))
        pan.setTranslation(.zero, in: self)
    }

    @objc private func hovered(_ hover: UIHoverGestureRecognizer) {
        switch hover.state {
        case .began, .changed: onTouch(.hover(hover.location(in: self)))
        default: onTouch(.hover(nil))
        }
    }

    // A pinch whose first finger lands a moment early doesn't paint, and once painting has
    // begun a second finger doesn't zoom.
    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        if recognizer === drag || recognizer === tap { return recognizer.numberOfTouches <= 1 && pinchCenter == nil }
        if recognizer === pinch || recognizer === twoFingerPan { return dragStart == nil }
        return true
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let twoFingers: [UIGestureRecognizer] = [pinch, twoFingerPan]
        if twoFingers.contains(where: { $0 === recognizer }) && twoFingers.contains(where: { $0 === other }) { return true }
        return recognizer === hover || other === hover
    }
}
