import ProofKit
import simd
import SwiftUI

/// Guided Upright's tool on the photo, as in Lightroom: a drag draws a line along something that
/// should be upright or level, and the photo is corrected to it at once. The guides drawn so far
/// are shown where they now fall on the corrected photo. A temporary tool, so it may sit on the
/// photo. The canvas shows the whole photo meanwhile, uncropped and unturned, so a guide can
/// reach any edge.
struct GuideOverlay: View {
    let library: Library
    let zoom: CanvasZoom
    /// The correction the canvas shows.
    let transform: PerspectiveTransform
    /// The photo as the camera oriented it, in pixels: the space the correction works in.
    let photoSize: CGSize

    /// The guide being drawn, in points; `nil` while none is.
    @State private var drawn: (start: CGPoint, end: CGPoint)?

    var body: some View {
        GeometryReader { geometry in
            let photo = photoRect(in: geometry.size)
            let map = transform.homography(for: photoSize)
            Canvas { context, _ in
                var lines = Path()
                for guide in transform.guides {
                    let start = shown(guide.start, map: map, photo: photo), end = shown(guide.end, map: map, photo: photo)
                    lines.move(to: start); lines.addLine(to: end)
                    for point in [start, end] {
                        lines.addEllipse(in: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
                    }
                }
                if let drawn {
                    lines.move(to: drawn.start); lines.addLine(to: drawn.end)
                }
                var shadowed = context
                shadowed.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5))
                shadowed.stroke(lines, with: .color(.white), lineWidth: 1.5)
            }
            .contentShape(Rectangle())
            .pointerStyle(.rectSelection)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in drawn = (value.startLocation, value.location) }
                    .onEnded { value in
                        drawn = nil
                        // A click without a drag draws nothing.
                        guard hypot(value.location.x - value.startLocation.x,
                                    value.location.y - value.startLocation.y) >= 8,
                              let start = source(of: value.startLocation, map: map, photo: photo),
                              let end = source(of: value.location, map: map, photo: photo) else { return }
                        library.addGuide(GuideLine(start: start, end: end))
                    })
        }
        // What to do, on the photo where it happens, until a guide shows it. Material and the
        // label color keep it gray in either appearance.
        .overlay(alignment: .top) {
            if transform.guides.isEmpty {
                Label("Drag along an edge that should be straight", systemImage: "pencil.line")
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 12)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: transform.guides.isEmpty)
        .accessibilityElement()
        .accessibilityLabel("Guides")
        .accessibilityValue("\(transform.guides.count) of \(Library.maximumGuides) drawn")
    }

    /// The photo's rectangle on the canvas, in points.
    private func photoRect(in size: CGSize) -> CGRect {
        guard size.width > 0, zoom.viewSize.width > 0, zoom.photoSize.width > 0 else { return .zero }
        // The viewport works in drawable pixels; the canvas in points.
        let pointsPerPixel = size.width / zoom.viewSize.width
        let pixels = zoom.viewport.frame(photo: zoom.photoSize, view: zoom.viewSize)
        return CGRect(x: pixels.minX * pointsPerPixel, y: pixels.minY * pointsPerPixel,
                      width: pixels.width * pointsPerPixel, height: pixels.height * pointsPerPixel)
    }

    /// Where a point of the uncorrected photo, from 0 to 1, now shows on the canvas.
    private func shown(_ point: CGPoint, map: simd_double3x3, photo: CGRect) -> CGPoint {
        let size = SIMD2(Double(photoSize.width), Double(photoSize.height))
        let corrected = PerspectiveTransform.apply(map, to: SIMD2(point.x, point.y) * size) / size
        return CGPoint(x: photo.minX + corrected.x * photo.width, y: photo.minY + corrected.y * photo.height)
    }

    /// The point of the uncorrected photo, from 0 to 1, that shows at `point` on the canvas, or
    /// `nil` before the photo has been laid out.
    private func source(of point: CGPoint, map: simd_double3x3, photo: CGRect) -> CGPoint? {
        guard photo.width > 0, photo.height > 0 else { return nil }
        let size = SIMD2(Double(photoSize.width), Double(photoSize.height))
        let shown = SIMD2((point.x - photo.minX) / photo.width, (point.y - photo.minY) / photo.height)
        let source = PerspectiveTransform.apply(map.inverse, to: shown * size) / size
        return CGPoint(x: source.x, y: source.y)
    }
}
