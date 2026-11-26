import ProofKit
import simd
import SwiftUI

/// Where Guided Upright's guides show on the guide tool, which covers the canvas, and which point
/// of the uncorrected photo shows where. The guides are shown where they now fall on the corrected
/// photo, as cropped and zoomed, so opening the tool moves nothing. Each app's tool turns its own
/// input into these points.
@MainActor
public struct GuideLayout {
    /// The photo's rectangle on the tool, in points.
    public let photo: CGRect
    /// Each guide's ends where they now fall on the tool.
    public let ends: [(CGPoint, CGPoint)]
    /// The correction the canvas shows, from the uncorrected photo's pixels to the corrected one's.
    private let map: simd_double3x3
    /// The crop the canvas shows, which comes after the correction.
    private let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space the correction works in.
    private let photoSize: CGSize

    #if os(iOS)
    private static let reach = GuideReach.touch
    #else
    private static let reach = GuideReach.pointer
    #endif

    /// - Parameter size: The tool's size, in points, which is the canvas's.
    public init(size: CGSize, zoom: CanvasZoom, transform: PerspectiveTransform, crop: Crop?, photoSize: CGSize) {
        self.crop = crop
        self.photoSize = photoSize
        map = transform.homography(for: photoSize)
        if size.width > 0, zoom.viewSize.width > 0, zoom.photoSize.width > 0 {
            // The viewport works in drawable pixels; the tool in points.
            let pointsPerPixel = size.width / zoom.viewSize.width
            let pixels = zoom.viewport.frame(photo: zoom.photoSize, view: zoom.viewSize)
            photo = CGRect(x: pixels.minX * pointsPerPixel, y: pixels.minY * pointsPerPixel,
                           width: pixels.width * pointsPerPixel, height: pixels.height * pointsPerPixel)
        } else {
            photo = .zero
        }
        let (map, photo) = (map, photo)
        ends = transform.guides.map {
            (Self.shown($0.start, map: map, crop: crop, photoSize: photoSize, photo: photo),
             Self.shown($0.end, map: map, crop: crop, photoSize: photoSize, photo: photo))
        }
    }

    /// The part of a guide at `location`.
    public func part(at location: CGPoint) -> GuidePart? {
        Self.reach.part(at: location, ends: ends)
    }

    /// Where a point of the uncorrected photo, from 0 to 1, now shows on the tool: corrected,
    /// then cropped.
    private static func shown(_ point: CGPoint, map: simd_double3x3, crop: Crop?, photoSize: CGSize, photo: CGRect) -> CGPoint {
        let size = SIMD2(Double(photoSize.width), Double(photoSize.height))
        let corrected = PerspectiveTransform.apply(map, to: SIMD2(point.x, point.y) * size) / size
        let result = crop?.resultPoint(of: CGPoint(x: corrected.x, y: corrected.y), photoSize: photoSize)
            ?? CGPoint(x: corrected.x, y: corrected.y)
        return CGPoint(x: photo.minX + result.x * photo.width, y: photo.minY + result.y * photo.height)
    }

    /// The point of the uncorrected photo, from 0 to 1, that shows at `location` on the tool, or
    /// `nil` before the photo has been laid out.
    public func source(of location: CGPoint) -> CGPoint? {
        guard photo.width > 0, photo.height > 0 else { return nil }
        let size = SIMD2(Double(photoSize.width), Double(photoSize.height))
        var shown = CGPoint(x: (location.x - photo.minX) / photo.width, y: (location.y - photo.minY) / photo.height)
        if let crop { shown = crop.photoPoint(of: shown, photoSize: photoSize) }
        let source = PerspectiveTransform.apply(map.inverse, to: SIMD2(shown.x, shown.y) * size) / size
        return CGPoint(x: source.x, y: source.y)
    }
}

/// One press on the guide tool, by pointer, finger or Pencil, from when it lands to when it
/// lifts. A press on a guide's end moves that end and one on its line moves the whole guide; a
/// drag anywhere else draws a new guide. The photo is corrected when the press lifts; meanwhile
/// the line follows the press.
@MainActor
public struct GuidePress {
    private enum Drag {
        case drawing(start: CGPoint, end: CGPoint)
        case moving(GuidePart, by: CGSize)
    }
    private var drag: Drag?
    /// The part pressed last. Its guide is the selected one; a chosen end, or both ends of a
    /// chosen line, are filled.
    public private(set) var selected: GuidePart?

    /// How far a press moves, in points, before it moves a guide rather than selecting it.
    static let clickDistance = 2.0
    /// How long a drag must be, in points, to draw a guide.
    static let shortestGuide = 8.0

    public init() {}

    /// A guide is being drawn or moved.
    public var isActive: Bool { drag != nil }

    /// A new guide is being drawn.
    public var isDrawing: Bool { drawing != nil }

    /// The press, which landed at `start`, is now at `location`.
    public mutating func moved(from start: CGPoint, to location: CGPoint, layout: GuideLayout) {
        let translation = CGSize(width: location.x - start.x, height: location.y - start.y)
        switch drag {
        case let .moving(part, _)?:
            drag = .moving(part, by: translation)
        case .drawing?:
            drag = .drawing(start: start, end: location)
        case nil:
            if let part = layout.part(at: start) {
                drag = .moving(part, by: translation)
            } else {
                drag = .drawing(start: start, end: location)
            }
        }
    }

    /// The press, which landed at `start`, lifted at `location`.
    public mutating func ended(from start: CGPoint, at location: CGPoint, layout: GuideLayout, library: Library) {
        defer { drag = nil }
        let moved = hypot(location.x - start.x, location.y - start.y)
        switch drag {
        case let .moving(part, offset)?:
            select(part, library: library)
            // A click or tap only selects.
            guard moved >= Self.clickDistance, layout.ends.indices.contains(part.index) else { return }
            let (start, end) = Self.ends(layout.ends[part.index], moving: part, by: offset)
            guard let a = layout.source(of: start), let b = layout.source(of: end) else { return }
            library.setGuide(at: part.index, to: GuideLine(start: a, end: b))
        case let .drawing(start, end)?:
            // A click or tap on nothing clears the selection.
            guard moved >= Self.shortestGuide else { select(nil, library: library); return }
            guard let a = layout.source(of: start), let b = layout.source(of: end) else { return }
            library.addGuide(GuideLine(start: a, end: b))
        case nil:
            break
        }
    }

    /// The press was taken by another gesture, such as a pinch, so it changes nothing.
    public mutating func cancel() {
        drag = nil
    }

    private mutating func select(_ part: GuidePart?, library: Library) {
        selected = part
        library.selectedGuide = part?.index
    }

    /// A guide's ends, `part` of it moved by `offset`.
    static func ends(_ guide: (CGPoint, CGPoint), moving part: GuidePart, by offset: CGSize) -> (CGPoint, CGPoint) {
        var (start, end) = guide
        if part != .end(index: part.index, isStart: false) { start = CGPoint(x: start.x + offset.width, y: start.y + offset.height) }
        if part != .end(index: part.index, isStart: true) { end = CGPoint(x: end.x + offset.width, y: end.y + offset.height) }
        return (start, end)
    }

    /// Each guide's ends as drawn, with the one being moved where the press has it.
    func shownEnds(_ layout: GuideLayout) -> [(CGPoint, CGPoint)] {
        guard case let .moving(part, offset)? = drag else { return layout.ends }
        return layout.ends.enumerated().map { index, guide in
            index == part.index ? Self.ends(guide, moving: part, by: offset) : guide
        }
    }

    /// The guide being drawn, from where the press landed to where it is.
    var drawing: (CGPoint, CGPoint)? {
        guard case let .drawing(start, end)? = drag else { return nil }
        return (start, end)
    }

    /// Whether an end is drawn filled: while it is held, or when it or its guide's line was
    /// chosen last and its guide is still the selected one.
    func isFilled(_ end: GuidePart, selectedGuide: Int?) -> Bool {
        if case let .moving(part, _)? = drag, part == end { return true }
        guard selectedGuide == end.index else { return false }
        if selected == end { return true }
        if case let .line(index)? = selected, index == end.index { return true }
        return false
    }
}

/// The guides drawn on the guide tool: each guide's line, with a ring at each end, filled when
/// chosen. Nothing covers the photo but the guides.
public struct GuideMarks: View {
    let library: Library
    let layout: GuideLayout
    let press: GuidePress
    /// The end under the pointer, which is filled to show it can be moved.
    let hovered: GuidePart?

    #if os(iOS)
    private static let handleRadius = 6.0
    #else
    private static let handleRadius = 4.0
    #endif

    public init(library: Library, layout: GuideLayout, press: GuidePress, hovered: GuidePart? = nil) {
        self.library = library
        self.layout = layout
        self.press = press
        self.hovered = hovered
    }

    public var body: some View {
        let selectedGuide = library.selectedGuide
        Canvas { context, _ in
            var lines = Path(), rings = Path(), dots = Path()
            for (index, (start, end)) in press.shownEnds(layout).enumerated() {
                lines.move(to: start)
                lines.addLine(to: end)
                for (point, isStart) in [(start, true), (end, false)] {
                    let radius = Self.handleRadius
                    let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                                                        width: radius * 2, height: radius * 2))
                    let part = GuidePart.end(index: index, isStart: isStart)
                    if hovered == part || press.isFilled(part, selectedGuide: selectedGuide) {
                        dots.addPath(circle)
                    } else {
                        rings.addPath(circle)
                    }
                }
            }
            if let (start, end) = press.drawing {
                lines.move(to: start)
                lines.addLine(to: end)
            }
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5))
            shadowed.stroke(lines, with: .color(.white), lineWidth: 1.5)
            // Hollow, so the edge underneath shows through, until chosen.
            shadowed.fill(rings, with: .color(.black.opacity(0.35)))
            shadowed.stroke(rings, with: .color(.white), lineWidth: 1.5)
            shadowed.fill(dots, with: .color(.white))
        }
    }
}
