import AppKit
import ProofKit
import SwiftUI

/// The pointer outside a crop corner, and on the Masks tool's turning handles. macOS has no
/// rotate cursor, so this draws one in the style of its resize cursors: a black curved arrow
/// with a white outline, curving around the corner.
@MainActor
enum RotateCursor {
    private static var images: [CropHandle: NSImage] = [:]

    static func image(for corner: CropHandle) -> NSImage {
        if let image = images[corner] { return image }
        // Drawn for the top right corner, then turned a quarter turn clockwise per corner.
        let turns: Double = switch corner {
        case .topRight: 0
        case .bottomRight: 1
        case .bottomLeft: 2
        default: 3
        }
        let size = 24.0
        let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
            let transform = NSAffineTransform()
            transform.translateX(by: size / 2, yBy: size / 2)
            transform.rotate(byDegrees: turns * 90)
            transform.translateX(by: -size / 2, yBy: -size / 2)
            transform.concat()

            // A quarter circle bulging toward the corner, from its top end to its right end.
            let center = NSPoint(x: 6, y: 18), radius = 11.0
            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: -86, endAngle: -4, clockwise: false)
            let heads = NSBezierPath()
            for (point, direction) in [(NSPoint(x: center.x, y: center.y - radius), CGVector(dx: -1, dy: 0)),
                                       (NSPoint(x: center.x + radius, y: center.y), CGVector(dx: 0, dy: 1))] {
                heads.move(to: NSPoint(x: point.x + 3 * direction.dx, y: point.y + 3 * direction.dy))
                heads.line(to: NSPoint(x: point.x - 1.5 * direction.dx + 3.2 * direction.dy, y: point.y - 1.5 * direction.dy + 3.2 * direction.dx))
                heads.line(to: NSPoint(x: point.x - 1.5 * direction.dx - 3.2 * direction.dy, y: point.y - 1.5 * direction.dy - 3.2 * direction.dx))
                heads.close()
            }
            NSColor.white.set()
            arc.lineWidth = 4.5
            arc.stroke()
            heads.lineWidth = 2.5
            heads.lineJoinStyle = .round
            heads.stroke()
            heads.fill()
            NSColor.black.set()
            arc.lineWidth = 1.5
            arc.stroke()
            heads.fill()
            return true
        }
        images[corner] = image
        return image
    }
}
