import AppKit
import ProofKit
import ProofUI
import SwiftUI

/// The Spot Removal tool on the photo: a click covers the spot under it, filled from a nearby
/// area Proof chooses, and a drag paints a stroke over a longer mark, such as a hair. Each spot
/// shows as its outline; the selected one also shows the area it takes from, joined to it by a
/// line. Dragging a spot moves it, and Delete removes the selected spot. Return, Esc and Q close it, and nothing covers the photo but the circles. The pointer shows the next spot's size, which [ and ] change. Pinching zooms and dragging
/// with the space bar held pans, as on the canvas, which the tool covers; the keyboard and the
/// navigator zoom as usual. A temporary tool, so it may sit on the photo.
struct SpotOverlay: View {
    let library: Library
    let renderer: RAWRenderer
    let zoom: CanvasZoom
    /// The crop the canvas shows.
    let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space spots are placed in.
    let photoSize: CGSize

    /// What part of a spot a press is on.
    private enum Part: Equatable {
        case spot(Int)
        case source(Int)

        var index: Int {
            switch self {
            case let .spot(index), let .source(index): index
            }
        }
    }

    @State private var pointer: CGPoint?
    @State private var hovered: Part?
    /// The part being dragged, and where its center was when the drag started, in points.
    @State private var dragging: (part: Part, start: CGPoint)?
    @FocusState private var isFocused: Bool
    /// The space bar is held, so a drag pans instead of placing or moving a spot.
    @State private var isSpaceDown = false
    /// The drag's translation when it last panned, while a drag is panning.
    @State private var panned: CGSize?
    /// Where the stroke being painted last took a point, in points, while painting.
    @State private var painted: CGPoint?
    /// The pinch's magnification when it last zoomed, while pinching.
    @State private var pinched: CGFloat?
    @State private var keyMonitor: Any?

    /// Spots smaller than this on screen, in points, are still drawn and taken at this radius.
    private static let minimumRadius = 4.0
    /// How much [ and ] change the size by.
    private static let sizeStep = 1.15
    /// How far the pointer moves, in points, before a press on the photo paints rather than clicks.
    private static let clickDistance = 4.0
    /// How far apart a stroke's points are taken, in points on screen.
    private static let pointSpacing = 2.0

    var body: some View {
        GeometryReader { geometry in
            let photo = photoRect(in: geometry.size)
            // Where the tool is in the window, for scrolling, which the window's monitor sees.
            let _ = updateFrame(geometry.frame(in: .global))
            let spots = library.selectedEdit?.recipe.spots ?? []
            let selected = library.selectedSpot.flatMap { spots.indices.contains($0) ? $0 : nil }
            Canvas { context, _ in
                var circles = Path(), chosen = Path(), sourceCircle = Path(), link = Path()
                for (index, spot) in spots.enumerated() {
                    let center = shown(spot.center, photo: photo)
                    let radius = shownRadius(spot.radius, photo: photo)
                    let circle = outline(of: spot, photo: photo)
                    if index == selected || hovered?.index == index {
                        chosen.addPath(circle)
                    } else {
                        circles.addPath(circle)
                    }
                    // The source shows once Proof has chosen it, so it doesn't jump, and not
                    // while a stroke is painted, when it takes from itself.
                    guard index == selected, library.findingSourceFor != index, painted == nil else { continue }
                    let source = shown(spot.source, photo: photo)
                    sourceCircle.addPath(outline(of: spot, photo: photo,
                                                 moved: CGVector(dx: source.x - center.x, dy: source.y - center.y)))
                    // From edge to edge, so the line doesn't cross either circle.
                    let dx = source.x - center.x, dy = source.y - center.y
                    let distance = hypot(dx, dy)
                    if distance > radius * 2 {
                        let ux = dx / distance, uy = dy / distance
                        link.move(to: CGPoint(x: center.x + ux * radius, y: center.y + uy * radius))
                        link.addLine(to: CGPoint(x: source.x - ux * radius, y: source.y - uy * radius))
                    }
                }
                // The next spot's size at the pointer, over the photo but not over a spot.
                var brush = Path()
                if let pointer, hovered == nil, dragging == nil, panned == nil, painted == nil, !isSpaceDown,
                   photo.contains(pointer) {
                    let radius = shownRadius(library.nextSpot.radius, photo: photo)
                    brush.addEllipse(in: CGRect(x: pointer.x - radius, y: pointer.y - radius, width: radius * 2, height: radius * 2))
                }
                var shadowed = context
                shadowed.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5))
                shadowed.stroke(circles, with: .color(.white.opacity(0.8)), lineWidth: 1)
                shadowed.stroke(chosen, with: .color(.white), lineWidth: 2)
                shadowed.stroke(sourceCircle, with: .color(.white), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                shadowed.stroke(link, with: .color(.white), lineWidth: 1)
                shadowed.stroke(brush, with: .color(.white.opacity(0.7)), lineWidth: 1)
            }
            .contentShape(Rectangle())
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .onAppear {
                isFocused = true
                watchKeys()
            }
            .onDisappear {
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
            }
            .accessibilityElement()
            .accessibilityLabel("Photo")
            .accessibilityValue(spots.count == 1 ? "1 spot" : "\(spots.count) spots")
            .accessibilityHint("Click a blemish to remove it, or drag over a longer one, such as a hair")
            .pointerStyle(pointerStyle)
            .onContinuousHover { phase in
                if case let .active(location) = phase {
                    pointer = location
                    hovered = part(at: location, spots: spots, selected: selected, photo: photo)
                } else {
                    pointer = nil
                    hovered = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if panned != nil || (dragging == nil && isSpaceDown) {
                            let last = panned ?? .zero
                            let pixelsPerPoint = zoom.viewSize.width / max(geometry.size.width, 1)
                            zoom.pan(by: CGVector(dx: (value.translation.width - last.width) * pixelsPerPoint,
                                                  dy: (value.translation.height - last.height) * pixelsPerPoint))
                            panned = value.translation
                            return
                        }
                        if let last = painted {
                            guard hypot(value.location.x - last.x, value.location.y - last.y) >= Self.pointSpacing,
                                  let point = point(at: value.location, photo: photo) else { return }
                            library.extendStroke(to: point)
                            painted = value.location
                            return
                        }
                        if dragging == nil {
                            guard let part = part(at: value.startLocation, spots: spots, selected: selected, photo: photo) else {
                                // A drag on the photo away from every spot paints a stroke.
                                guard hypot(value.translation.width, value.translation.height) >= Self.clickDistance,
                                      photo.contains(value.startLocation),
                                      let start = point(at: value.startLocation, photo: photo),
                                      let point = point(at: value.location, photo: photo)
                                else { return }
                                isFocused = true
                                library.beginStroke(at: start)
                                library.extendStroke(to: point)
                                painted = value.location
                                return
                            }
                            let spot = spots[part.index]
                            dragging = (part, shown(part == .spot(part.index) ? spot.center : spot.source, photo: photo))
                            library.selectSpot(part.index)
                            isFocused = true
                        }
                        guard let (part, start) = dragging, hypot(value.translation.width, value.translation.height) >= 2,
                              let moved = point(at: CGPoint(x: start.x + value.translation.width, y: start.y + value.translation.height),
                                                photo: photo)
                        else { return }
                        library.isAdjusting = true
                        switch part {
                        case let .spot(index): library.moveSpot(at: index, to: moved)
                        case let .source(index): library.moveSpot(at: index, source: moved)
                        }
                    }
                    .onEnded { value in
                        if panned != nil {
                            panned = nil
                            return
                        }
                        if dragging != nil {
                            dragging = nil
                            library.isAdjusting = false
                            return
                        }
                        if painted != nil {
                            painted = nil
                            Task { await library.finishStroke(with: renderer) }
                            return
                        }
                        // A click on the photo away from every spot covers a new one there.
                        guard hypot(value.translation.width, value.translation.height) < Self.clickDistance,
                              photo.contains(value.location), let center = point(at: value.location, photo: photo)
                        else {
                            library.selectSpot(nil)
                            return
                        }
                        isFocused = true
                        Task { await library.addSpot(at: center, with: renderer) }
                    })
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let pixelsPerPoint = zoom.viewSize.width / max(geometry.size.width, 1)
                        zoom.zoom(by: value.magnification / (pinched ?? 1),
                                  keeping: CGPoint(x: value.startLocation.x * pixelsPerPoint,
                                                   y: value.startLocation.y * pixelsPerPoint))
                        pinched = value.magnification
                    }
                    .onEnded { _ in pinched = nil })
        }
        // Return and Esc close the tool, wherever the keyboard focus is, as the menu's Q does.
        .background {
            Group {
                Button("Done Removing Spots") { library.finishRemovingSpots() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Close Spot Removal") { library.finishRemovingSpots() }
                    .keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    private var pointerStyle: PointerStyle {
        if panned != nil || dragging != nil { return .grabActive }
        if isSpaceDown { return .grabIdle }
        return hovered == nil ? .default : .grabIdle
    }

    /// Follows the tool's keys while it is open, wherever the keyboard focus is, as long as no
    /// text is being typed: a click on the photo or a slider would otherwise take them away.
    /// The space bar pans while held, Delete removes the selected spot, and [ and ] change the size.
    private func watchKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .scrollWheel]) { event in
            if event.type == .scrollWheel { return scroll(event) ? nil : event }
            guard !(NSApp.keyWindow?.firstResponder is NSText),
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            switch event.keyCode {
            case 49:
                isSpaceDown = event.type == .keyDown
                return nil
            case 51, 117:
                guard let index = library.selectedSpot else { return event }
                if event.type == .keyDown { library.removeSpot(at: index) }
                return nil
            default:
                guard let key = event.charactersIgnoringModifiers, key == "[" || key == "]" else { return event }
                if event.type == .keyDown {
                    let factor = key == "]" ? Self.sizeStep : 1 / Self.sizeStep
                    library.changeSpot { spot in
                        spot.radius = min(max(spot.radius * factor, Spot.radiusRange.lowerBound), Spot.radiusRange.upperBound)
                    }
                }
                return nil
            }
        }
    }

    /// Pans with a two-finger scroll, or zooms with ⌘-scroll, as the canvas under the tool does,
    /// for a scroll over the tool. Returns whether it used the event.
    private func scroll(_ event: NSEvent) -> Bool {
        guard let window = event.window, let content = window.contentView, zoom.isEnabled, frame.width > 0 else { return false }
        // The window's coordinates point up; SwiftUI's point down.
        let location = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        guard frame.contains(location) else { return false }
        let pixelsPerPoint = zoom.viewSize.width / frame.width
        // A mouse wheel reports lines rather than points.
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
        if event.modifierFlags.contains(.command) {
            let point = CGPoint(x: (location.x - frame.minX) * pixelsPerPoint, y: (location.y - frame.minY) * pixelsPerPoint)
            zoom.zoom(by: exp(event.scrollingDeltaY * step * 0.01), keeping: point)
        } else if zoom.canPan {
            zoom.pan(by: CGVector(dx: event.scrollingDeltaX * step * pixelsPerPoint,
                                  dy: event.scrollingDeltaY * step * pixelsPerPoint))
        }
        return true
    }

    /// Kept outside SwiftUI's state, since it is set while the view is drawn.
    private final class FrameBox { var frame = CGRect.zero }
    @State private var frameBox = FrameBox()
    private var frame: CGRect { frameBox.frame }
    private func updateFrame(_ frame: CGRect) { frameBox.frame = frame }

    /// The selected spot's source before any spot, then the topmost spot, within its outline.
    private func part(at location: CGPoint, spots: [Spot], selected: Int?, photo: CGRect) -> Part? {
        if let selected {
            let spot = spots[selected]
            let center = shown(spot.center, photo: photo), source = shown(spot.source, photo: photo)
            if distance(from: location, to: spot, photo: photo, moved: CGVector(dx: source.x - center.x, dy: source.y - center.y))
                <= shownRadius(spot.radius, photo: photo) {
                return .source(selected)
            }
        }
        for (index, spot) in spots.enumerated().reversed()
        where distance(from: location, to: spot, photo: photo) <= shownRadius(spot.radius, photo: photo) {
            return .spot(index)
        }
        return nil
    }

    /// The points a spot is drawn around on the canvas: its center, or a stroke's path, moved by
    /// `offset` points.
    private func shownPath(of spot: Spot, photo: CGRect, moved offset: CGVector) -> [CGPoint] {
        (spot.isStroke ? spot.path : [spot.center]).map {
            let point = shown($0, photo: photo)
            return CGPoint(x: point.x + offset.dx, y: point.y + offset.dy)
        }
    }

    /// The edge of what a spot covers on the canvas, moved by `offset` points for its source.
    private func outline(of spot: Spot, photo: CGRect, moved offset: CGVector = .zero) -> Path {
        let radius = shownRadius(spot.radius, photo: photo)
        let points = shownPath(of: spot, photo: photo, moved: offset)
        guard spot.isStroke else {
            return Path(ellipseIn: CGRect(x: points[0].x - radius, y: points[0].y - radius, width: radius * 2, height: radius * 2))
        }
        var line = Path()
        line.addLines(points)
        // Normalized, so where the stroke crosses itself only the outer edge shows.
        return line.strokedPath(StrokeStyle(lineWidth: radius * 2, lineCap: .round, lineJoin: .round)).normalized()
    }

    /// How far `location` is from a spot's center, or from a stroke's path, in points.
    private func distance(from location: CGPoint, to spot: Spot, photo: CGRect, moved offset: CGVector = .zero) -> Double {
        let points = shownPath(of: spot, photo: photo, moved: offset)
        guard points.count > 1 else { return hypot(location.x - points[0].x, location.y - points[0].y) }
        return zip(points, points.dropFirst()).map { a, b in
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared > 0 ? min(max(((location.x - a.x) * dx + (location.y - a.y) * dy) / lengthSquared, 0), 1) : 0
            return hypot(location.x - (a.x + t * dx), location.y - (a.y + t * dy))
        }.min() ?? .infinity
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

    /// Where a point of the uncropped photo, from 0 to 1, shows on the canvas.
    private func shown(_ point: CGPoint, photo: CGRect) -> CGPoint {
        let result = crop?.resultPoint(of: point, photoSize: photoSize) ?? point
        return CGPoint(x: photo.minX + result.x * photo.width, y: photo.minY + result.y * photo.height)
    }

    /// A spot's radius on the canvas, in points. `zoom.photoSize` is the cropped photo at full
    /// size, which the photo's rectangle shows.
    private func shownRadius(_ radius: Double, photo: CGRect) -> Double {
        guard zoom.photoSize.width > 0 else { return Self.minimumRadius }
        let pointsPerPixel = photo.width / zoom.photoSize.width
        return max(radius * max(photoSize.width, photoSize.height) * pointsPerPixel, Self.minimumRadius)
    }

    /// The point of the uncropped photo, from 0 to 1, that shows at `location`, kept on the
    /// photo; `nil` before the photo has been laid out.
    private func point(at location: CGPoint, photo: CGRect) -> CGPoint? {
        guard photo.width > 0, photo.height > 0 else { return nil }
        let shown = CGPoint(x: (location.x - photo.minX) / photo.width, y: (location.y - photo.minY) / photo.height)
        let point = crop?.photoPoint(of: shown, photoSize: photoSize) ?? shown
        return CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}
