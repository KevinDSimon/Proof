import ProofKit
import simd
import SwiftUI

/// Guided Upright's tool on the photo, as in Lightroom: a drag draws a line along something that
/// should be upright or level, and the photo is corrected to it when the drag ends. Dragging a
/// guide's end moves that end, dragging its line moves the whole guide, and clicking either
/// selects the guide for Delete to remove. The guides are shown where they now fall on the
/// corrected photo, as cropped and zoomed, so opening the tool moves nothing. A temporary tool,
/// so it may sit on the photo.
struct GuideOverlay: View {
    let library: Library
    let zoom: CanvasZoom
    /// The correction the canvas shows.
    let transform: PerspectiveTransform
    /// The crop the canvas shows, which comes after the correction.
    let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space the correction works in.
    let photoSize: CGSize

    /// What part of a guide a press is on.
    private enum Part: Equatable {
        case end(index: Int, isStart: Bool)
        case line(index: Int)

        var index: Int {
            switch self {
            case let .end(index, _), let .line(index): index
            }
        }
    }

    /// What a drag on the photo is doing, in points: drawing a new guide, or moving one end or
    /// all of a drawn guide. The photo is corrected when the drag ends; meanwhile the line
    /// follows the pointer.
    private enum Drag {
        case drawing(start: CGPoint, end: CGPoint)
        case moving(Part, by: CGSize)
    }
    @State private var drag: Drag?
    /// The part under the pointer, which takes an open-hand pointer to show it can be moved.
    @State private var hovered: Part?
    /// The part clicked or dragged last. Its guide is the one Delete removes; a chosen end, or
    /// both ends of a chosen line, are filled.
    @State private var selected: Part?
    /// Held while a guide is selected, so Delete reaches it.
    @FocusState private var isFocused: Bool

    /// How close, in points, a press must be to a guide's end to take the end.
    private static let endReach = 10.0
    /// How close, in points, a press must be to a guide's line to take the line.
    private static let lineReach = 6.0
    private static let handleRadius = 4.0

    var body: some View {
        GeometryReader { geometry in
            let photo = photoRect(in: geometry.size)
            let map = transform.homography(for: photoSize)
            let ends = shownEnds(map: map, photo: photo)
            Canvas { context, _ in
                var lines = Path(), rings = Path(), dots = Path()
                for (index, guide) in ends.enumerated() {
                    var (start, end) = guide
                    if case let .moving(part, offset)? = drag, part.index == index {
                        if part != .end(index: index, isStart: false) { start = start + offset }
                        if part != .end(index: index, isStart: true) { end = end + offset }
                    }
                    lines.move(to: start); lines.addLine(to: end)
                    for (point, isStart) in [(start, true), (end, false)] {
                        let circle = Path(ellipseIn: CGRect(x: point.x - Self.handleRadius, y: point.y - Self.handleRadius,
                                                            width: Self.handleRadius * 2, height: Self.handleRadius * 2))
                        if isFilled(.end(index: index, isStart: isStart)) { dots.addPath(circle) } else { rings.addPath(circle) }
                    }
                }
                if case let .drawing(start, end)? = drag {
                    lines.move(to: start); lines.addLine(to: end)
                }
                var shadowed = context
                shadowed.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5))
                shadowed.stroke(lines, with: .color(.white), lineWidth: 1.5)
                // Hollow, so the edge underneath shows through, until chosen.
                shadowed.fill(rings, with: .color(.black.opacity(0.35)))
                shadowed.stroke(rings, with: .color(.white), lineWidth: 1.5)
                shadowed.fill(dots, with: .color(.white))
            }
            .contentShape(Rectangle())
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            // Delete, and Edit › Delete, remove the selected guide.
            .onDeleteCommand {
                guard let index = selected?.index else { return }
                selected = nil
                library.removeGuide(at: index)
            }
            .onChange(of: transform.guides.count) { selected = nil }
            .accessibilityElement()
            .accessibilityLabel("Guides")
            .accessibilityValue("\(transform.guides.count) of \(Library.maximumGuides) drawn")
            .pointerStyle(pointer)
            .onContinuousHover { phase in
                if case let .active(location) = phase { hovered = part(at: location, in: ends) } else { hovered = nil }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        switch drag {
                        case let .moving(part, _)?:
                            drag = .moving(part, by: value.translation)
                        case .drawing?:
                            drag = .drawing(start: value.startLocation, end: value.location)
                        case nil:
                            if let part = part(at: value.startLocation, in: ends) {
                                drag = .moving(part, by: value.translation)
                            } else {
                                drag = .drawing(start: value.startLocation, end: value.location)
                            }
                        }
                    }
                    .onEnded { value in
                        defer { drag = nil }
                        let moved = hypot(value.translation.width, value.translation.height)
                        switch drag {
                        case let .moving(part, offset)?:
                            select(part)
                            // A click only selects.
                            guard moved >= 2 else { return }
                            let (start, end) = ends[part.index]
                            let newStart = part == .end(index: part.index, isStart: false) ? start : start + offset
                            let newEnd = part == .end(index: part.index, isStart: true) ? end : end + offset
                            guard let a = source(of: newStart, map: map, photo: photo),
                                  let b = source(of: newEnd, map: map, photo: photo) else { return }
                            library.setGuide(at: part.index, to: GuideLine(start: a, end: b))
                        case .drawing?:
                            // A click on nothing clears the selection.
                            guard moved >= 8 else { select(nil); return }
                            guard let start = source(of: value.startLocation, map: map, photo: photo),
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
                Text(instructions + (transform.guides.isEmpty ? "" : " · \(transform.guides.count) of \(Library.maximumGuides)"))
                    .monospacedDigit()
                Button("Clear All") { library.clearGuides() }
                    .disabled(transform.guides.isEmpty)
                    .accessibilityLabel("Clear All Guides")
                // Return keeps the guides and closes the tool, as Done does elsewhere; so does Esc.
                Button("Done") { library.isDrawingGuides = false }
                    .keyboardShortcut(.return, modifiers: [])
                    .help("Keep the guides and stop drawing (Return)")
                    .background {
                        Button("") { library.isDrawingGuides = false }
                            .keyboardShortcut(.cancelAction)
                            .opacity(0)
                            .accessibilityHidden(true)
                    }
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
    }

    /// What to do next, leading the pill.
    private var instructions: String {
        if selected != nil { return "Press Delete to remove the selected guide" }
        if transform.guides.isEmpty { return "Drag along an edge that should be straight" }
        return "Drag along another edge, or drag a guide to adjust"
    }

    private var pointer: PointerStyle {
        switch drag {
        case .moving?: .grabActive
        case .drawing?: .rectSelection
        case nil: hovered == nil ? .rectSelection : .grabIdle
        }
    }

    /// Whether an end is drawn filled: while the pointer is on it or it is held, or when it or
    /// its guide's line was chosen last.
    private func isFilled(_ end: Part) -> Bool {
        if hovered == end || selected == end { return true }
        if case let .moving(part, _)? = drag, part == end { return true }
        if case let .line(index)? = selected, index == end.index { return true }
        return false
    }

    /// Selects `part`, or nothing, and takes focus so Delete reaches its guide.
    private func select(_ part: Part?) {
        selected = part
        if part != nil { isFocused = true }
    }

    /// The part of a guide at `point`: an end within reach, before a line within reach, the
    /// nearest of each.
    private func part(at point: CGPoint, in ends: [(CGPoint, CGPoint)]) -> Part? {
        var bestEnd: (part: Part, distance: Double)?
        var bestLine: (part: Part, distance: Double)?
        for (index, guide) in ends.enumerated() {
            for (end, isStart) in [(guide.0, true), (guide.1, false)] {
                let distance = hypot(end.x - point.x, end.y - point.y)
                if distance <= Self.endReach, distance < (bestEnd?.distance ?? .infinity) {
                    bestEnd = (.end(index: index, isStart: isStart), distance)
                }
            }
            let (a, b) = guide
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1) : 0
            let distance = hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
            if distance <= Self.lineReach, distance < (bestLine?.distance ?? .infinity) { bestLine = (.line(index: index), distance) }
        }
        return bestEnd?.part ?? bestLine?.part
    }

    /// Each guide's ends where they now fall on the canvas.
    private func shownEnds(map: simd_double3x3, photo: CGRect) -> [(CGPoint, CGPoint)] {
        transform.guides.map { (shown($0.start, map: map, photo: photo), shown($0.end, map: map, photo: photo)) }
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

    /// Where a point of the uncorrected photo, from 0 to 1, now shows on the canvas: corrected,
    /// then cropped.
    private func shown(_ point: CGPoint, map: simd_double3x3, photo: CGRect) -> CGPoint {
        let size = SIMD2(Double(photoSize.width), Double(photoSize.height))
        let corrected = PerspectiveTransform.apply(map, to: SIMD2(point.x, point.y) * size) / size
        let result = crop?.resultPoint(of: CGPoint(x: corrected.x, y: corrected.y), photoSize: photoSize)
            ?? CGPoint(x: corrected.x, y: corrected.y)
        return CGPoint(x: photo.minX + result.x * photo.width, y: photo.minY + result.y * photo.height)
    }

    /// The point of the uncorrected photo, from 0 to 1, that shows at `point` on the canvas, or
    /// `nil` before the photo has been laid out.
    private func source(of point: CGPoint, map: simd_double3x3, photo: CGRect) -> CGPoint? {
        guard photo.width > 0, photo.height > 0 else { return nil }
        let size = SIMD2(Double(photoSize.width), Double(photoSize.height))
        var shown = CGPoint(x: (point.x - photo.minX) / photo.width, y: (point.y - photo.minY) / photo.height)
        if let crop { shown = crop.photoPoint(of: shown, photoSize: photoSize) }
        let source = PerspectiveTransform.apply(map.inverse, to: SIMD2(shown.x, shown.y) * size) / size
        return CGPoint(x: source.x, y: source.y)
    }
}

private extension CGPoint {
    static func + (point: CGPoint, offset: CGSize) -> CGPoint {
        CGPoint(x: point.x + offset.width, y: point.y + offset.height)
    }
}
