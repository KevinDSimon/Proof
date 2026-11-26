import ProofKit
import SwiftUI

/// What part of a spot a press is on.
public enum SpotPart: Equatable, Sendable {
    case spot(Int)
    case source(Int)

    public var index: Int {
        switch self {
        case let .spot(index), let .source(index): index
        }
    }
}

/// Where the photo's spots show on the Spot Removal tool, which covers the canvas, and which
/// point of the photo shows where. Each app's tool turns its own input into these points.
@MainActor
public struct SpotLayout {
    /// The photo's rectangle on the tool, in points.
    public let photo: CGRect
    /// The cropped photo at full size, in pixels, which `photo` shows.
    private let shownSize: CGSize
    /// The crop the canvas shows.
    private let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space spots are placed in.
    private let photoSize: CGSize

    /// Spots smaller than this on screen, in points, are still drawn and taken at this radius.
    static let minimumRadius = 4.0
    /// How far spots reach for a press: a finger's farther than a pointer's.
    #if os(iOS)
    private static let reach = SpotReach.touch
    #else
    private static let reach = SpotReach.pointer
    #endif

    /// - Parameter size: The tool's size, in points, which is the canvas's.
    public init(size: CGSize, zoom: CanvasZoom, crop: Crop?, photoSize: CGSize) {
        shownSize = zoom.photoSize
        self.crop = crop
        self.photoSize = photoSize
        guard size.width > 0, zoom.viewSize.width > 0, zoom.photoSize.width > 0 else {
            photo = .zero
            return
        }
        // The viewport works in drawable pixels; the tool in points.
        let pointsPerPixel = size.width / zoom.viewSize.width
        let pixels = zoom.viewport.frame(photo: zoom.photoSize, view: zoom.viewSize)
        photo = CGRect(x: pixels.minX * pointsPerPixel, y: pixels.minY * pointsPerPixel,
                       width: pixels.width * pointsPerPixel, height: pixels.height * pointsPerPixel)
    }

    /// The selected spot's source before any spot, then the topmost spot, within its outline.
    /// On touch, a press near no outline takes the nearest spot or source within reach.
    public func part(at location: CGPoint, spots: [Spot], selected: Int?) -> SpotPart? {
        var parts = spots.indices.reversed().map { SpotPart.spot($0) }
        if let selected { parts.insert(.source(selected), at: 0) }
        let distances = parts.map { part in
            let spot = spots[part.index]
            return distance(from: location, to: spot, moved: part == .source(part.index) ? sourceOffset(of: spot) : .zero)
        }
        let radii = parts.map { shownRadius(spots[$0.index].radius) }
        return Self.reach.target(distances: distances, radii: radii).map { parts[$0] }
    }

    /// How far a spot's source is from it on the canvas, in points.
    func sourceOffset(of spot: Spot) -> CGVector {
        let center = shown(spot.center), source = shown(spot.source)
        return CGVector(dx: source.x - center.x, dy: source.y - center.y)
    }

    /// The points a spot is drawn around on the canvas: its center, or a stroke's path, moved by
    /// `offset` points.
    private func shownPath(of spot: Spot, moved offset: CGVector) -> [CGPoint] {
        (spot.isStroke ? spot.path : [spot.center]).map {
            let point = shown($0)
            return CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
        }
    }

    /// The edge of what a spot covers on the canvas, moved by `offset` points for its source.
    func outline(of spot: Spot, moved offset: CGVector = .zero) -> Path {
        let radius = shownRadius(spot.radius)
        let points = shownPath(of: spot, moved: offset)
        guard spot.isStroke else {
            return Path(ellipseIn: CGRect(x: points[0].x - radius, y: points[0].y - radius, width: radius * 2, height: radius * 2))
        }
        var line = Path()
        line.addLines(points)
        // Normalized, so where the stroke crosses itself only the outer edge shows.
        return line.strokedPath(StrokeStyle(lineWidth: radius * 2, lineCap: .round, lineJoin: .round)).normalized()
    }

    /// How far `location` is from a spot's center, or from a stroke's path, in points.
    private func distance(from location: CGPoint, to spot: Spot, moved offset: CGVector = .zero) -> Double {
        let points = shownPath(of: spot, moved: offset)
        guard points.count > 1 else { return hypot(location.x - points[0].x, location.y - points[0].y) }
        return zip(points, points.dropFirst()).map { a, b in
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(max(((location.x - a.x) * dx + (location.y - a.y) * dy) / lengthSquared, 0), 1) : 0
            return hypot(location.x - (a.x + t * dx), location.y - (a.y + t * dy))
        }.min() ?? .infinity
    }

    /// Where a point of the uncropped photo, from 0 to 1, shows on the canvas.
    public func shown(_ point: CGPoint) -> CGPoint {
        let result = crop?.resultPoint(of: point, photoSize: photoSize) ?? point
        return CGPoint(x: photo.minX + result.x * photo.width, y: photo.minY + result.y * photo.height)
    }

    /// A spot's radius on the canvas, in points.
    func shownRadius(_ radius: Double) -> Double {
        guard shownSize.width > 0 else { return Self.minimumRadius }
        let pointsPerPixel = photo.width / shownSize.width
        return max(radius * max(photoSize.width, photoSize.height) * pointsPerPixel, Self.minimumRadius)
    }

    /// The point of the uncropped photo, from 0 to 1, that shows at `location`, kept on the
    /// photo; `nil` before the photo has been laid out.
    public func point(at location: CGPoint) -> CGPoint? {
        guard photo.width > 0, photo.height > 0 else { return nil }
        let shown = CGPoint(x: (location.x - photo.minX) / photo.width, y: (location.y - photo.minY) / photo.height)
        let point = crop?.photoPoint(of: shown, photoSize: photoSize) ?? shown
        return CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}

/// One press on the Spot Removal tool, by pointer, finger or Pencil, from when it lands to when
/// it lifts. A press on a spot or the selected spot's source selects it and drags it; a drag
/// away from every spot paints a stroke (decision 0047); a press that hardly moves covers a new
/// spot there.
@MainActor
public struct SpotPress {
    /// The part being dragged, and where its center was when the drag started, in points.
    private var dragging: (part: SpotPart, start: CGPoint)?
    /// Where the stroke being painted last took a point, in points, while painting.
    public private(set) var painted: CGPoint?

    /// How far a press moves, in points, before it paints rather than clicks.
    static let clickDistance = 4.0
    /// How far apart a stroke's points are taken, in points on screen.
    static let pointSpacing = 2.0

    public init() {}

    /// A spot is being moved or a stroke painted.
    public var isActive: Bool { dragging != nil || painted != nil }

    /// The press, which landed at `start`, is now at `location`. Returns whether it is now moving
    /// a spot or painting.
    @discardableResult
    public mutating func moved(from start: CGPoint, to location: CGPoint, layout: SpotLayout, library: Library) -> Bool {
        let translation = CGSize(width: location.x - start.x, height: location.y - start.y)
        if let last = painted {
            guard hypot(location.x - last.x, location.y - last.y) >= Self.pointSpacing,
                  let point = layout.point(at: location) else { return true }
            library.extendStroke(to: point)
            painted = location
            return true
        }
        if dragging == nil {
            let spots = library.selectedEdit?.recipe.spots ?? []
            let selected = library.selectedSpot.flatMap { spots.indices.contains($0) ? $0 : nil }
            guard let part = layout.part(at: start, spots: spots, selected: selected) else {
                guard hypot(translation.width, translation.height) >= Self.clickDistance,
                      layout.photo.contains(start),
                      let first = layout.point(at: start),
                      let point = layout.point(at: location)
                else { return false }
                library.beginStroke(at: first)
                library.extendStroke(to: point)
                painted = location
                return true
            }
            let spot = spots[part.index]
            dragging = (part, layout.shown(part == .spot(part.index) ? spot.center : spot.source))
            library.selectSpot(part.index)
        }
        guard let (part, origin) = dragging else { return false }
        guard hypot(translation.width, translation.height) >= 2,
              let moved = layout.point(at: CGPoint(x: origin.x + translation.width, y: origin.y + translation.height))
        else { return true }
        library.isAdjusting = true
        switch part {
        case let .spot(index): library.moveSpot(at: index, to: moved)
        case let .source(index): library.moveSpot(at: index, source: moved)
        }
        return true
    }

    /// The press lifted at `location`, `distance` points from where it landed. Returns whether
    /// it covered a new spot.
    @discardableResult
    public mutating func ended(at location: CGPoint, distance: Double, layout: SpotLayout, library: Library,
                               renderer: RAWRenderer) -> Bool {
        if dragging != nil {
            dragging = nil
            library.isAdjusting = false
            return false
        }
        if painted != nil {
            painted = nil
            Task { await library.finishStroke(with: renderer) }
            return false
        }
        // A press on the photo away from every spot covers a new one there.
        guard distance < Self.clickDistance, layout.photo.contains(location), let center = layout.point(at: location) else {
            library.selectSpot(nil)
            return false
        }
        Task { await library.addSpot(at: center, with: renderer) }
        return true
    }
}

/// The spots drawn on the Spot Removal tool: each spot's outline, and the selected one's source,
/// dashed, joined to it by a line. Nothing covers the photo but the outlines.
public struct SpotMarks: View {
    let library: Library
    let layout: SpotLayout
    /// Where to show the next spot's size, as the pointer or a hovering Pencil.
    let brush: CGPoint?
    let hovered: SpotPart?
    let isPainting: Bool

    public init(library: Library, layout: SpotLayout, brush: CGPoint?, hovered: SpotPart?, isPainting: Bool) {
        self.library = library
        self.layout = layout
        self.brush = brush
        self.hovered = hovered
        self.isPainting = isPainting
    }

    public var body: some View {
        let spots = library.selectedEdit?.recipe.spots ?? []
        let selected = library.selectedSpot.flatMap { spots.indices.contains($0) ? $0 : nil }
        Canvas { context, _ in
            var circles = Path(), chosen = Path(), sourceCircle = Path(), link = Path()
            for (index, spot) in spots.enumerated() {
                let center = layout.shown(spot.center)
                let radius = layout.shownRadius(spot.radius)
                let circle = layout.outline(of: spot)
                if index == selected || hovered?.index == index {
                    chosen.addPath(circle)
                } else {
                    circles.addPath(circle)
                }
                // The source shows once Proof has chosen it, so it doesn't jump, and not
                // while a stroke is painted, when it takes from itself.
                guard index == selected, library.findingSourceFor != index, !isPainting else { continue }
                let offset = layout.sourceOffset(of: spot)
                sourceCircle.addPath(layout.outline(of: spot, moved: offset))
                // From edge to edge, so the line doesn't cross either circle.
                let distance = hypot(offset.dx, offset.dy)
                if distance > radius * 2 {
                    let ux = offset.dx / distance, uy = offset.dy / distance
                    link.move(to: CGPoint(x: center.x + ux * radius, y: center.y + uy * radius))
                    link.addLine(to: CGPoint(x: center.x + offset.dx - ux * radius, y: center.y + offset.dy - uy * radius))
                }
            }
            // The next spot's size, over the photo but not over a spot.
            var outline = Path()
            if let brush, layout.photo.contains(brush) {
                let radius = layout.shownRadius(library.nextSpot.radius)
                outline.addEllipse(in: CGRect(x: brush.x - radius, y: brush.y - radius, width: radius * 2, height: radius * 2))
            }
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5))
            shadowed.stroke(circles, with: .color(.white.opacity(0.8)), lineWidth: 1)
            shadowed.stroke(chosen, with: .color(.white), lineWidth: 2)
            shadowed.stroke(sourceCircle, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            shadowed.stroke(link, with: .color(.white), lineWidth: 1)
            shadowed.stroke(outline, with: .color(.white.opacity(0.7)), lineWidth: 1)
        }
    }
}
