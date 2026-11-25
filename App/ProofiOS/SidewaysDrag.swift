import ProofUI
import SwiftUI
import UIKit

/// A pan that starts only when the finger first moves more sideways than up or down. The scroll
/// view around it waits for it to fail, so a drag up or down still scrolls, as in Photos.
struct SidewaysDrag: UIGestureRecognizerRepresentable {
    let actions: SidewaysDragActions

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        pan.isEnabled = actions.isEnabled
        return pan
    }

    func updateUIGestureRecognizer(_ pan: UIPanGestureRecognizer, context: Context) {
        pan.isEnabled = actions.isEnabled
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        // In the grid's coordinates, which scroll with it.
        let point = context.converter.location(in: actions.coordinateSpace)
        switch pan.state {
        case .began:
            // Where the finger first touched, not where the pan was recognized.
            let moved = pan.translation(in: pan.view)
            actions.began(CGPoint(x: point.x - moved.x, y: point.y - moved.y))
            actions.changed(point)
        case .changed:
            actions.changed(point)
        default:
            break
        }
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            (other.view as? UIScrollView)?.panGestureRecognizer === other
        }
    }
}
