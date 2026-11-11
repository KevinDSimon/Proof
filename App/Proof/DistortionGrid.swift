import ProofKit
import SwiftUI

/// Square grid lines over the photo while the Distortion slider is dragged, as in Lightroom, so
/// lines in the photo can be lined up against straight ones. A temporary tool, so it may sit on
/// the photo. Drawn like the crop tool's grid.
struct DistortionGrid: View {
    let zoom: CanvasZoom

    /// Squares along the photo's short edge: an even number, so the middle lines run through the
    /// center and the edges land on lines. A 3:2 or 4:3 photo then fits whole squares both ways.
    static let squares = 12.0

    var body: some View {
        Canvas { context, size in
            guard size.width > 0, zoom.viewSize.width > 0, zoom.photoSize.width > 0 else { return }
            // The viewport works in drawable pixels; the canvas in points.
            let pointsPerPixel = size.width / zoom.viewSize.width
            let pixels = zoom.viewport.frame(photo: zoom.photoSize, view: zoom.viewSize)
            let photo = CGRect(x: pixels.minX * pointsPerPixel, y: pixels.minY * pointsPerPixel,
                               width: pixels.width * pointsPerPixel, height: pixels.height * pointsPerPixel)
            let shown = photo.intersection(CGRect(origin: .zero, size: size))
            guard !shown.isEmpty else { return }
            // Centered on the photo, so the middle lines run through its center, where the
            // correction moves nothing.
            let step = min(photo.width, photo.height) / Self.squares
            var grid = Path()
            var x = photo.midX - (((photo.midX - shown.minX) / step).rounded(.down)) * step
            while x <= shown.maxX {
                grid.move(to: CGPoint(x: x, y: shown.minY)); grid.addLine(to: CGPoint(x: x, y: shown.maxY))
                x += step
            }
            var y = photo.midY - (((photo.midY - shown.minY) / step).rounded(.down)) * step
            while y <= shown.maxY {
                grid.move(to: CGPoint(x: shown.minX, y: y)); grid.addLine(to: CGPoint(x: shown.maxX, y: y))
                y += step
            }
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.45), radius: 1))
            shadowed.stroke(grid, with: .color(.white.opacity(0.6)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
