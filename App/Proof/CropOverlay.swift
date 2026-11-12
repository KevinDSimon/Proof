import ProofKit
import SwiftUI

/// The crop rectangle drawn over the photo while the crop tool is open: the area outside it
/// faded toward the canvas, a border with handles, and a grid while something is being dragged.
/// It lays out the same way `RAWRenderer.draw` does: the turned photo fitted to the view as if
/// upright, then tilted around its center by the straighten angle.
struct CropOverlay: View {
    let library: Library
    let frame: CropFrame
    let aspect: AspectRatio?
    let backdropGray: Double

    /// The rectangle when the current drag started; `nil` between drags.
    @State private var dragStart: CropFrame?

    var body: some View {
        GeometryReader { proxy in
            let layout = Layout(frame: frame, viewSize: proxy.size)
            ZStack {
                Canvas { context, size in
                    draw(in: &context, size: size, layout: layout)
                }
                .allowsHitTesting(false)
                // Beneath the rectangle and its handles, so only the part outside each corner turns the photo.
                ForEach(Self.corners, id: \.self) { corner in
                    let point = layout.point(of: corner)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: 2 * Self.rotateReach, height: 2 * Self.rotateReach)
                        .position(point)
                        .pointerStyle(.image(Image(nsImage: RotateCursor.image(for: corner)), hotSpot: .center))
                        .gesture(rotate(around: CGPoint(x: layout.box.midX, y: layout.box.midY)))
                        .accessibilityHidden(true)
                }
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: max(layout.box.width - 2 * Self.handleReach, 0),
                           height: max(layout.box.height - 2 * Self.handleReach, 0))
                    .position(x: layout.box.midX, y: layout.box.midY)
                    .pointerStyle(dragStart == nil ? .grabIdle : .grabActive)
                    .gesture(drag(layout: layout) { start, delta in start.moved(by: delta) })
                    .accessibilityHidden(true)
                ForEach(CropHandle.allCases, id: \.self) { handle in
                    let area = layout.hitArea(of: handle, reach: Self.handleReach)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: area.width, height: area.height)
                        .position(x: area.midX, y: area.midY)
                        .pointerStyle(.frameResize(position: handle.resizePosition))
                        .gesture(drag(layout: layout) { start, delta in start.dragging(handle, by: delta, aspect: aspect) })
                        .accessibilityHidden(true)
                }
                // Over the rectangle and its handles, so the drag draws a line wherever it starts,
                // or moves the line kept from before or one of its ends.
                if library.isDrawingLevelLine {
                    let ends = shownLevelEnds(layout: layout)
                    Color.clear
                        .contentShape(Rectangle())
                        .pointerStyle(levelDrag.map { if case .drawing = $0 { .rectSelection } else { .grabActive } }
                                      ?? (hoveredLevelPart == nil ? .rectSelection : .grabIdle))
                        .onContinuousHover { phase in
                            if case let .active(location) = phase { hoveredLevelPart = levelPart(at: location, in: ends) } else { hoveredLevelPart = nil }
                        }
                        .gesture(levelLine(layout: layout, ends: ends))
                        .accessibilityHidden(true)
                }
            }
        }
        // What to do, with the ruler's own buttons, as Guided Upright's guides have.
        .overlay(alignment: .top) {
            if library.isDrawingLevelLine {
                ToolPill(message: library.levelLine == nil ? "Drag along something that should be level or upright"
                                                           : "Drag the line or its ends to adjust",
                         doneHelp: "Keep the angle and stop drawing (Return)",
                         done: { library.isDrawingLevelLine = false }) {
                    Button("Clear") { library.clearLevelLine() }
                        .disabled(library.levelLine == nil)
                        .accessibilityLabel("Clear Level Line")
                }
            }
        }
    }

    private enum LevelDrag {
        /// A new line, in points.
        case drawing(start: CGPoint, end: CGPoint)
        /// An end or all of the kept line, with the line and the straighten angle when the drag started.
        case moving(LevelPart, line: LevelLine, angle: Double)
    }
    /// What part of the kept line a press is on, as for Guided Upright's guides.
    private enum LevelPart: Equatable {
        case start, end, line
    }
    @State private var levelDrag: LevelDrag?
    /// The part of the kept line under the pointer.
    @State private var hoveredLevelPart: LevelPart?

    /// How close, in points, a press must be to an end of the kept line to take it.
    private static let levelEndReach = 10.0
    /// How close, in points, a press must be to the kept line to take all of it.
    private static let levelLineReach = 6.0
    private static let levelEndRadius = 4.0

    /// The kept line's ends where they now fall in the view.
    private func shownLevelEnds(layout: Layout) -> (start: CGPoint, end: CGPoint)? {
        guard let line = library.levelLine else { return nil }
        let shown = { point in
            let offset = LevelLine.shownPoint(of: point, scale: layout.scale, angle: frame.angle)
            return CGPoint(x: layout.photoCenter.x + offset.x, y: layout.photoCenter.y + offset.y)
        }
        return (shown(line.start), shown(line.end))
    }

    /// The part of the kept line at `point`: the nearer end within reach, before the line.
    private func levelPart(at point: CGPoint, in ends: (start: CGPoint, end: CGPoint)?) -> LevelPart? {
        guard let (a, b) = ends else { return nil }
        let toStart = hypot(a.x - point.x, a.y - point.y)
        let toEnd = hypot(b.x - point.x, b.y - point.y)
        if min(toStart, toEnd) <= Self.levelEndReach { return toStart <= toEnd ? .start : .end }
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        let t = lengthSquared > 0 ? min(max(((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared, 0), 1) : 0
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy)) <= Self.levelLineReach ? .line : nil
    }

    /// Draws a new line to level the photo along, or moves an end of the kept one, which turns
    /// the photo as it goes. The line is kept on the photo, so it stays on what it was drawn along.
    private func levelLine(layout: Layout, ends: (start: CGPoint, end: CGPoint)?) -> some Gesture {
        let center = layout.photoCenter
        return DragGesture(minimumDistance: 0)
            .onChanged { value in
                if levelDrag == nil {
                    if let part = levelPart(at: value.startLocation, in: ends), let line = library.levelLine {
                        levelDrag = .moving(part, line: line, angle: frame.angle)
                        library.isStraightening = true
                        library.isAdjusting = true
                    } else {
                        levelDrag = .drawing(start: value.startLocation, end: value.location)
                    }
                }
                switch levelDrag {
                case .drawing?:
                    levelDrag = .drawing(start: value.startLocation, end: value.location)
                case let .moving(part, line, angle)?:
                    // Mapped with the angle from the drag's start, so the photo turning under the
                    // pointer doesn't feed back into where the end goes. Moving all of the line
                    // keeps its angle, so the photo stays still.
                    let shown = CGPoint(x: value.location.x - center.x, y: value.location.y - center.y)
                    library.level(along: part == .line
                        ? line.moved(by: CGVector(dx: value.translation.width, dy: value.translation.height), scale: layout.scale, angle: angle)
                        : line.moving(isStart: part == .start, to: shown, scale: layout.scale, angle: angle))
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer { levelDrag = nil }
                switch levelDrag {
                case .drawing?:
                    // A click without a drag changes nothing.
                    guard hypot(value.translation.width, value.translation.height) >= 8 else { return }
                    library.level(along: LevelLine(
                        shownFrom: CGPoint(x: value.startLocation.x - center.x, y: value.startLocation.y - center.y),
                        to: CGPoint(x: value.location.x - center.x, y: value.location.y - center.y),
                        scale: layout.scale, angle: frame.angle))
                case .moving?:
                    library.isStraightening = false
                    library.isAdjusting = false
                case nil:
                    break
                }
            }
    }

    /// How far from the border a drag still takes a handle, in points.
    private static let handleReach = 12.0
    /// How far outside a corner a drag turns the photo, in points.
    private static let rotateReach = 36.0
    private static let corners: [CropHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]

    /// The straighten angle and the turn's center when the current corner drag started.
    @State private var rotateStart: (angle: Double, center: CGPoint)?

    /// Turns the photo with the pointer around the rectangle's center, as the straighten slider does.
    private func rotate(around center: CGPoint) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                // The rectangle shrinks as the photo turns; its center at the start stays the pivot.
                let start = rotateStart ?? (library.selectedCrop.angle, center)
                if rotateStart == nil {
                    rotateStart = start
                    library.isStraightening = true
                    library.isAdjusting = true
                }
                let turn = Horizon.turn(around: start.center, from: value.startLocation, to: value.location)
                library.setStraighten(start.angle + turn)
            }
            .onEnded { _ in
                rotateStart = nil
                library.isStraightening = false
                library.isAdjusting = false
            }
    }

    private func drag(layout: Layout, change: @escaping (CropFrame, CGVector) -> CropFrame) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let start = dragStart ?? frame
                if dragStart == nil {
                    dragStart = start
                    library.isAdjusting = true
                }
                // The rectangle stays upright on screen, so a drag is already along its edges.
                let delta = CGVector(dx: value.translation.width / layout.scale, dy: value.translation.height / layout.scale)
                library.setCropFrame(change(start, delta))
            }
            .onEnded { _ in
                dragStart = nil
                library.isAdjusting = false
            }
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, layout: Layout) {
        let box = layout.box
        // Fades the photo outside the rectangle toward the canvas, in either appearance.
        var outside = Path(CGRect(origin: .zero, size: size))
        outside.addRect(box)
        context.fill(outside, with: .color(Color(white: backdropGray).opacity(0.7)), style: FillStyle(eoFill: true))

        let line = Color.white
        var shadowed = context
        shadowed.addFilter(.shadow(color: .black.opacity(0.45), radius: 1))

        let divisions = library.isStraightening || levelDrag != nil ? 8 : dragStart != nil ? 3 : 0
        if divisions > 0 {
            var grid = Path()
            for index in 1..<divisions {
                let x = box.minX + box.width * Double(index) / Double(divisions)
                let y = box.minY + box.height * Double(index) / Double(divisions)
                grid.move(to: CGPoint(x: x, y: box.minY)); grid.addLine(to: CGPoint(x: x, y: box.maxY))
                grid.move(to: CGPoint(x: box.minX, y: y)); grid.addLine(to: CGPoint(x: box.maxX, y: y))
            }
            shadowed.stroke(grid, with: .color(line.opacity(0.6)), lineWidth: 0.5)
        }

        shadowed.stroke(Path(box), with: .color(line), lineWidth: 1)

        // Corner brackets and short bars at the middle of each edge.
        let length = min(20, box.width / 3, box.height / 3)
        var handles = Path()
        let inset = 1.5
        let (left, right, top, bottom) = (box.minX + inset, box.maxX - inset, box.minY + inset, box.maxY - inset)
        for (x, y, dx, dy) in [(left, top, 1.0, 1.0), (right, top, -1.0, 1.0), (right, bottom, -1.0, -1.0), (left, bottom, 1.0, -1.0)] {
            handles.move(to: CGPoint(x: x + dx * length, y: y))
            handles.addLine(to: CGPoint(x: x, y: y))
            handles.addLine(to: CGPoint(x: x, y: y + dy * length))
        }
        handles.move(to: CGPoint(x: box.midX - length / 2, y: top)); handles.addLine(to: CGPoint(x: box.midX + length / 2, y: top))
        handles.move(to: CGPoint(x: box.midX - length / 2, y: bottom)); handles.addLine(to: CGPoint(x: box.midX + length / 2, y: bottom))
        handles.move(to: CGPoint(x: left, y: box.midY - length / 2)); handles.addLine(to: CGPoint(x: left, y: box.midY + length / 2))
        handles.move(to: CGPoint(x: right, y: box.midY - length / 2)); handles.addLine(to: CGPoint(x: right, y: box.midY + length / 2))
        shadowed.stroke(handles, with: .color(line), style: StrokeStyle(lineWidth: 3, lineCap: .square))

        // A new line while one is being drawn, otherwise the kept line with a ring at each end.
        if case let .drawing(start, end)? = levelDrag {
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            shadowed.stroke(path, with: .color(line), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
        } else if library.isDrawingLevelLine, let ends = shownLevelEnds(layout: layout) {
            var path = Path(), rings = Path(), dots = Path()
            path.move(to: ends.start)
            path.addLine(to: ends.end)
            for (point, isStart) in [(ends.start, true), (ends.end, false)] {
                let radius = Self.levelEndRadius
                let circle = Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius))
                let part: LevelPart = isStart ? .start : .end
                var isHeld = false
                if case let .moving(held, _, _)? = levelDrag { isHeld = held == part }
                if isHeld || hoveredLevelPart == part { dots.addPath(circle) } else { rings.addPath(circle) }
            }
            shadowed.stroke(path, with: .color(line), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            // Hollow, as the Transform guides' ends are, so the edge underneath shows through.
            shadowed.fill(rings, with: .color(.black.opacity(0.35)))
            shadowed.stroke(rings, with: .color(line), lineWidth: 1.5)
            shadowed.fill(dots, with: .color(line))
        }
    }

    /// Where the rectangle sits in the view.
    struct Layout {
        let scale: Double
        let box: CGRect
        /// The photo's center, which it turns around: the middle of the view.
        let photoCenter: CGPoint

        init(frame: CropFrame, viewSize: CGSize) {
            let image = frame.imageSize
            photoCenter = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            scale = image.width > 0 && image.height > 0
                ? min(viewSize.width / image.width, viewSize.height / image.height) : 1
            // The photo turns around its own center; the rectangle's center turns with it.
            let radians = frame.angle * .pi / 180
            let dx = frame.center.x - image.width / 2, dy = frame.center.y - image.height / 2
            let center = CGPoint(x: viewSize.width / 2 + scale * (dx * cos(radians) - dy * sin(radians)),
                                 y: viewSize.height / 2 + scale * (dx * sin(radians) + dy * cos(radians)))
            let size = CGSize(width: frame.size.width * scale, height: frame.size.height * scale)
            box = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        }

        /// The corner or edge midpoint of the rectangle that `handle` sits on.
        func point(of handle: CropHandle) -> CGPoint {
            CGPoint(x: box.midX + Double(handle.horizontal) * box.width / 2,
                    y: box.midY + Double(handle.vertical) * box.height / 2)
        }

        /// The area that picks up `handle`: a square at a corner, the rest of the edge between.
        func hitArea(of handle: CropHandle, reach: Double) -> CGRect {
            let x: (Double, Double) = switch handle.horizontal {
            case -1: (box.minX - reach, box.minX + reach)
            case 1: (box.maxX - reach, box.maxX + reach)
            default: (box.minX + reach, box.maxX - reach)
            }
            let y: (Double, Double) = switch handle.vertical {
            case -1: (box.minY - reach, box.minY + reach)
            case 1: (box.maxY - reach, box.maxY + reach)
            default: (box.minY + reach, box.maxY - reach)
            }
            return CGRect(x: x.0, y: y.0, width: max(x.1 - x.0, 0), height: max(y.1 - y.0, 0))
        }
    }
}

private extension CropHandle {
    var resizePosition: FrameResizePosition {
        switch self {
        case .topLeft: .topLeading
        case .top: .top
        case .topRight: .topTrailing
        case .right: .trailing
        case .bottomRight: .bottomTrailing
        case .bottom: .bottom
        case .bottomLeft: .bottomLeading
        case .left: .leading
        }
    }
}

/// The pointer outside a crop corner. macOS has no rotate cursor, so this draws one in the style
/// of its resize cursors: a black curved arrow with a white outline, curving around the corner.
@MainActor
private enum RotateCursor {
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
