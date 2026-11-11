import ProofKit
import simd
import SwiftUI

/// Guided Upright's tool on the photo, as in Lightroom: a drag draws a line along something that
/// should be upright or level, and the photo is corrected to it at once. Dragging a guide's end
/// moves it. The guides drawn so far
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

    /// What a drag on the photo is doing, in points: drawing a new guide, or moving one end of a
    /// drawn guide. The photo is corrected when the drag ends; meanwhile the line follows the pointer.
    private enum Drag {
        case drawing(start: CGPoint, end: CGPoint)
        case moving(index: Int, isStart: Bool, to: CGPoint)
    }
    @State private var drag: Drag?
    /// The guide end under the pointer, which grows and takes an open-hand pointer to show it can be moved.
    @State private var hovered: (index: Int, isStart: Bool)?

    /// How close, in points, a press must be to a guide's end to move it rather than draw.
    private static let endReach = 10.0

    var body: some View {
        GeometryReader { geometry in
            let photo = photoRect(in: geometry.size)
            let map = transform.homography(for: photoSize)
            let ends = shownEnds(map: map, photo: photo)
            Canvas { context, _ in
                var lines = Path(), handles = Path()
                for (index, guide) in ends.enumerated() {
                    var (start, end) = guide
                    if case let .moving(moved, isStart, to)? = drag, moved == index {
                        if isStart { start = to } else { end = to }
                    }
                    lines.move(to: start); lines.addLine(to: end)
                    for (point, isStart) in [(start, true), (end, false)] {
                        let active = (hovered.map { $0.index == index && $0.isStart == isStart } ?? false)
                            || { if case let .moving(moved, movedStart, _)? = drag { return moved == index && movedStart == isStart }; return false }()
                        let radius = active ? 5.0 : 3.5
                        handles.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
                    }
                }
                if case let .drawing(start, end)? = drag {
                    lines.move(to: start); lines.addLine(to: end)
                }
                var shadowed = context
                shadowed.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5))
                shadowed.stroke(lines, with: .color(.white), lineWidth: 1.5)
                shadowed.fill(handles, with: .color(.white))
            }
            .contentShape(Rectangle())
            .pointerStyle(drag.map { if case .moving = $0 { return .grabActive }; return .rectSelection }
                          ?? (hovered == nil ? .rectSelection : .grabIdle))
            .onContinuousHover { phase in
                if case let .active(location) = phase { hovered = end(near: location, in: ends) } else { hovered = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if case let .moving(index, isStart, _)? = drag {
                            drag = .moving(index: index, isStart: isStart, to: value.location)
                        } else if case .drawing? = drag {
                            drag = .drawing(start: value.startLocation, end: value.location)
                        } else if let grabbed = end(near: value.startLocation, in: ends) {
                            drag = .moving(index: grabbed.index, isStart: grabbed.isStart, to: value.location)
                        } else {
                            drag = .drawing(start: value.startLocation, end: value.location)
                        }
                    }
                    .onEnded { value in
                        defer { drag = nil }
                        // A click without a drag changes nothing.
                        let moved = hypot(value.location.x - value.startLocation.x, value.location.y - value.startLocation.y)
                        switch drag {
                        case let .moving(index, isStart, to)?:
                            guard moved >= 2, let point = source(of: to, map: map, photo: photo) else { return }
                            library.moveGuideEnd(at: index, isStart: isStart, to: point)
                        case .drawing?:
                            guard moved >= 8,
                                  let start = source(of: value.startLocation, map: map, photo: photo),
                                  let end = source(of: value.location, map: map, photo: photo) else { return }
                            library.addGuide(GuideLine(start: start, end: end))
                        case nil:
                            break
                        }
                    })
        }
        // What to do, then how far along, with the tool's own buttons, on the photo where it
        // happens. Material and the label color keep it gray in either appearance.
        .overlay(alignment: .top) {
            HStack(spacing: 10) {
                Text(transform.guides.isEmpty
                        ? "Drag along an edge that should be straight"
                        : "Drag along another edge, or drag an end to adjust · \(transform.guides.count) of \(Library.maximumGuides)")
                    .monospacedDigit()
                Button("Clear") { library.clearGuides() }
                    .disabled(transform.guides.isEmpty)
                    .accessibilityLabel("Clear Guides")
                Button("Done") { library.isDrawingGuides = false }
                    .keyboardShortcut(.cancelAction)
                    .help("Stop drawing guides (Esc)")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
            .padding(.leading, 14)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 12)
        }
        .accessibilityElement()
        .accessibilityLabel("Guides")
        .accessibilityValue("\(transform.guides.count) of \(Library.maximumGuides) drawn")
    }

    /// Each guide's ends where they now fall on the canvas.
    private func shownEnds(map: simd_double3x3, photo: CGRect) -> [(CGPoint, CGPoint)] {
        transform.guides.map { (shown($0.start, map: map, photo: photo), shown($0.end, map: map, photo: photo)) }
    }

    /// The guide end within reach of `point`, the nearest if several are.
    private func end(near point: CGPoint, in ends: [(CGPoint, CGPoint)]) -> (index: Int, isStart: Bool)? {
        var best: (index: Int, isStart: Bool, distance: Double)?
        for (index, guide) in ends.enumerated() {
            for (end, isStart) in [(guide.0, true), (guide.1, false)] {
                let distance = hypot(end.x - point.x, end.y - point.y)
                if distance <= Self.endReach, distance < (best?.distance ?? .infinity) { best = (index, isStart, distance) }
            }
        }
        return best.map { ($0.index, $0.isStart) }
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
