import UIKit
import SwiftUI

/// What a touch on a tool drawn on the photo does, in the tool's points.
enum ToolTouch {
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
/// Pencil uses the tool, such as placing and painting spots or drawing guides, and two zoom and
/// pan, as on the canvas the tool covers.
struct ToolTouches: UIViewRepresentable {
    let onTouch: (ToolTouch) -> Void

    func makeUIView(context: Context) -> ToolTouchView { ToolTouchView() }

    func updateUIView(_ view: ToolTouchView, context: Context) {
        view.onTouch = onTouch
    }
}

final class ToolTouchView: UIView, UIGestureRecognizerDelegate {
    var onTouch: (ToolTouch) -> Void = { _ in }

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

    // A pinch whose first finger lands a moment early doesn't use the tool, and once a finger
    // is using it a second one doesn't zoom.
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
