import ProofKit
import SwiftUI

/// Where the masks show on the Masks tool, which covers the canvas, which part of a mask a press
/// is on, and which point of the photo shows where. Each app's tool turns its own input into
/// these points.
@MainActor
public struct MaskLayout {
    /// The photo's rectangle on the tool, in points.
    public let photo: CGRect
    /// The cropped photo at full size, in pixels, which `photo` shows.
    private let shownSize: CGSize
    /// The crop the canvas shows.
    private let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space masks are placed in.
    public let photoSize: CGSize

    /// How far pins and handles reach for a press: a finger's farther than a pointer's.
    #if os(iOS)
    static let reach = MaskReach.touch
    #else
    static let reach = MaskReach.pointer
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

    // MARK: Hit testing

    /// Pins first, the selected mask's before the topmost of the others, then the selected
    /// mask's handles and lines, the nearest within reach, then the inside of its ellipse.
    public func part(at location: CGPoint, library: Library) -> MaskPart? {
        func distance(to point: CGPoint) -> Double { hypot(location.x - point.x, location.y - point.y) }
        let layers = library.layers
        let selected = library.selectedLayer.flatMap { layers.indices.contains($0) ? $0 : nil }
        let order = (selected.map { [$0] } ?? []) + layers.indices.reversed().filter { $0 != selected }
        let pins = order.map { pinPoint(of: layers[$0].mask).map(distance) ?? .infinity }
        if let nearest = MaskReach.nearest(pins, within: Self.reach.pin) { return .pin(order[nearest]) }
        guard let layer = library.shownLayer else { return nil }
        switch layer.mask.shape {
        case let .linear(gradient):
            guard photo.contains(location) else { return nil }
            let lines = linearLines(gradient)
            // How far along the gradient's direction the location is from each line.
            func off(_ point: CGPoint) -> Double {
                abs((location.x - point.x) * lines.across.dy - (location.y - point.y) * lines.across.dx)
            }
            let parts: [MaskPart] = [.linearTurn, .linearStart, .linearEnd]
            return MaskReach.nearest([off(lines.middle), off(lines.start), off(lines.end)], within: Self.reach.handle)
                .map { parts[$0] }
        case let .radial(gradient):
            let shape = radialShape(gradient)
            let parts: [MaskPart] = [.radialTurn, .radialWidth, .radialHeight]
            if let nearest = MaskReach.nearest([shape.turn, shape.width, shape.height].map(distance), within: Self.reach.handle) {
                return parts[nearest]
            }
            if shape.outline.contains(location) { return .radialInside }
        case .brush, .subject, .unknown:
            break
        }
        return nil
    }

    // MARK: Geometry

    /// The three lines' points on the canvas, and the direction they run in, a unit vector.
    public func linearLines(_ gradient: LinearMask) -> (start: CGPoint, middle: CGPoint, end: CGPoint, across: CGVector) {
        let start = shown(gradient.start), end = shown(gradient.end)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let length = max(hypot(end.x - start.x, end.y - start.y), 0.001)
        return (start, middle, end, CGVector(dx: -(end.y - start.y) / length, dy: (end.x - start.x) / length))
    }

    /// The ellipse and where its feather starts, as paths on the canvas, with its handles: on the
    /// end of its width axis, on the top of its height axis, and above that, the turning handle.
    public func radialShape(_ gradient: RadialMask)
        -> (outline: Path, inner: Path, center: CGPoint, width: CGPoint, height: CGPoint, turn: CGPoint) {
        // Points of the ellipse in mask coordinates, from its angle and radii in pixels with y down.
        let long = max(photoSize.width, photoSize.height, 1)
        let angle = gradient.angle * .pi / 180
        let rx = gradient.radiusX * long, ry = gradient.radiusY * long
        func at(_ t: Double, scale: Double = 1) -> CGPoint {
            let x = rx * scale * cos(t), y = ry * scale * sin(t)
            let dx = x * cos(angle) - y * sin(angle), dy = x * sin(angle) + y * cos(angle)
            return shown(CGPoint(x: gradient.centerX + dx / photoSize.width, y: gradient.centerY + dy / photoSize.height))
        }
        func ellipse(scale: Double) -> Path {
            var path = Path()
            path.addLines((0...72).map { at(Double($0) / 72 * 2 * .pi, scale: scale) })
            path.closeSubpath()
            return path
        }
        let center = shown(gradient.center)
        let top = at(-.pi / 2)
        let up = CGVector(dx: top.x - center.x, dy: top.y - center.y)
        let length = max(hypot(up.dx, up.dy), 0.001)
        let feather = min(max(gradient.feather, 0), 100) / 100
        let offset = Self.reach.turnOffset
        return (ellipse(scale: 1), feather > 0.02 ? ellipse(scale: 1 - feather) : Path(), center, at(0), top,
                CGPoint(x: top.x + up.dx / length * offset, y: top.y + up.dy / length * offset))
    }

    /// Where a mask's pin goes: a linear gradient's middle, a radial one's center, where a brush
    /// mask's first stroke starts, or the middle of the subject.
    public func pinPoint(of mask: Mask) -> CGPoint? {
        switch mask.shape {
        case let .linear(gradient):
            shown(CGPoint(x: (gradient.startX + gradient.endX) / 2, y: (gradient.startY + gradient.endY) / 2))
        case let .radial(gradient):
            shown(gradient.center)
        case let .brush(brush):
            brush.strokes.first { !$0.erases }?.path.first.map(shown)
        case let .subject(subject):
            subject.center.map(shown)
        case .unknown:
            nil
        }
    }

    /// Where a point of the uncropped photo, from 0 to 1, shows on the canvas.
    public func shown(_ point: CGPoint) -> CGPoint {
        let result = crop?.resultPoint(of: point, photoSize: photoSize) ?? point
        return CGPoint(x: photo.minX + result.x * photo.width, y: photo.minY + result.y * photo.height)
    }

    /// The brush's radius on the canvas, in points.
    func shownRadius(_ radius: Double) -> Double {
        guard shownSize.width > 0 else { return 4 }
        return max(radius * max(photoSize.width, photoSize.height) * photo.width / shownSize.width, 2)
    }

    /// The point of the uncropped photo, from 0 to 1, that shows at `location`. Masks may reach
    /// past the photo, so it isn't kept on it; `nil` before the photo is laid out.
    public func point(at location: CGPoint) -> CGPoint? {
        guard photo.width > 0, photo.height > 0 else { return nil }
        let shown = CGPoint(x: (location.x - photo.minX) / photo.width, y: (location.y - photo.minY) / photo.height)
        return crop?.photoPoint(of: shown, photoSize: photoSize) ?? shown
    }
}

/// One press on the Masks tool, by pointer, finger or Pencil, from when it lands to when it
/// lifts. A press on a pin selects its mask and drags it; on the selected mask's lines, ellipse
/// or handles it moves, turns or sizes it; elsewhere on a selected brush mask it paints.
@MainActor
public struct MaskPress {
    private enum State {
        case moving(MaskPart, layer: Int, original: Mask, start: CGPoint)
        case painting(last: CGPoint)
    }

    private var state: State?

    public init() {}

    /// A mask is being moved or a stroke painted.
    public var isActive: Bool { state != nil }

    public var isPainting: Bool {
        if case .painting = state { return true }
        return false
    }

    /// The part being dragged, while one is.
    public var movingPart: MaskPart? {
        if case let .moving(part, _, _, _) = state { return part }
        return nil
    }

    /// The selected mask is a brush mask, so a press away from its pins paints.
    public static func paints(_ library: Library) -> Bool {
        guard case .brush = library.shownLayer?.mask.shape else { return false }
        return true
    }

    /// The press, which landed at `start`, is now at `location`, both in the tool's points.
    /// `flipsErasing` paints the other way from the Brush picker, as Option does on the Mac, and
    /// `snapsAngle` steps a radial turn by 15°, as Shift does.
    public mutating func moved(from start: CGPoint, to location: CGPoint, layout: MaskLayout, library: Library,
                               flipsErasing: Bool = false, snapsAngle: Bool = false) {
        if state == nil {
            guard let first = layout.point(at: start) else { return }
            switch layout.part(at: start, library: library) {
            case let .pin(index):
                library.selectLayer(index)
                state = .moving(.pin(index), layer: index, original: library.layers[index].mask, start: first)
            case let part?:
                guard let index = library.selectedLayer, let layer = library.shownLayer else { return }
                state = .moving(part, layer: index, original: layer.mask, start: first)
            case nil:
                guard Self.paints(library), layout.photo.contains(start) else { return }
                library.isAdjusting = true
                library.startStroke(at: first, erasing: library.isErasing != flipsErasing)
                state = .painting(last: first)
            }
        }
        guard let current = layout.point(at: location) else { return }
        switch state {
        case let .moving(part, layer, original, first):
            guard hypot(location.x - start.x, location.y - start.y) >= 2 else { return }
            library.isAdjusting = true
            let moved = original.moved(part, from: first, to: current, photoSize: layout.photoSize, snapsAngle: snapsAngle)
            library.changeLayer(at: layer) { $0.mask = moved }
        case let .painting(last):
            // Points closer than a quarter of the brush add nothing a smooth stroke needs.
            let size = layout.photoSize
            let distance = hypot((current.x - last.x) * size.width, (current.y - last.y) * size.height)
            guard distance >= library.nextStroke.radius * max(size.width, size.height) / 4 else { return }
            library.continueStroke(to: current)
            state = .painting(last: current)
        case nil:
            break
        }
    }

    /// The press lifted at `location`, in the tool's points.
    public mutating func ended(at location: CGPoint, layout: MaskLayout, library: Library) {
        defer { state = nil }
        switch state {
        case let .painting(last):
            if let end = layout.point(at: location), end != last { library.continueStroke(to: end) }
            library.isAdjusting = false
        case .moving:
            library.isAdjusting = false
        case nil:
            break
        }
    }
}

/// The masks drawn on the Masks tool: every mask's pin, gray with a white ring and black for the
/// selected one, the selected linear gradient's three lines or radial gradient's ellipse and
/// handles, and the brush's size where it would paint.
public struct MaskMarks: View {
    let library: Library
    let layout: MaskLayout
    /// Where to show the brush's size, as the pointer or a hovering Pencil.
    let brush: CGPoint?

    public init(library: Library, layout: MaskLayout, brush: CGPoint?) {
        self.library = library
        self.layout = layout
        self.brush = brush
    }

    public var body: some View {
        let layers = library.layers
        let reach = MaskLayout.reach
        // Handles are drawn larger for a finger, which covers them.
        let handleSize = reach == .touch ? 6.0 : 4.0
        Canvas { context, _ in
            let photo = layout.photo
            var thin = Path(), bold = Path(), dashed = Path(), handles = Path(), pins = Path(), chosenPin = Path()
            for (index, layer) in layers.enumerated() {
                guard let pin = layout.pinPoint(of: layer.mask) else { continue }
                if index == library.selectedLayer {
                    chosenPin.addEllipse(in: square(pin, reach.pinRadius))
                } else {
                    pins.addEllipse(in: square(pin, reach.pinRadius))
                }
            }
            if let layer = library.shownLayer {
                switch layer.mask.shape {
                case let .linear(gradient):
                    let lines = layout.linearLines(gradient)
                    for (point, isMiddle) in [(lines.start, false), (lines.middle, true), (lines.end, false)] {
                        var line = Path()
                        line.move(to: CGPoint(x: point.x - lines.across.dx * 5000, y: point.y - lines.across.dy * 5000))
                        line.addLine(to: CGPoint(x: point.x + lines.across.dx * 5000, y: point.y + lines.across.dy * 5000))
                        if isMiddle { bold.addPath(line) } else { thin.addPath(line) }
                    }
                case let .radial(gradient):
                    let shape = layout.radialShape(gradient)
                    bold.addPath(shape.outline)
                    dashed.addPath(shape.inner)
                    for handle in [shape.width, shape.height] { handles.addRect(square(handle, handleSize)) }
                    handles.addEllipse(in: square(shape.turn, handleSize))
                    thin.move(to: shape.height)
                    thin.addLine(to: shape.turn)
                case .brush, .subject, .unknown:
                    break
                }
            }
            // The brush's size, and where its feather starts.
            var outline = Path(), inner = Path()
            if let brush, photo.contains(brush) {
                let radius = layout.shownRadius(library.nextStroke.radius)
                outline.addEllipse(in: square(brush, radius))
                let feathered = radius * (1 - library.nextStroke.feather / 100)
                if feathered > 1 { inner.addEllipse(in: square(brush, feathered)) }
            }
            var clipped = context
            clipped.clip(to: Path(photo))
            clipped.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5))
            clipped.stroke(thin, with: .color(.white.opacity(0.85)), lineWidth: 1)
            clipped.stroke(bold, with: .color(.white), lineWidth: 1.5)
            clipped.stroke(dashed, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            var shadowed = context
            shadowed.addFilter(.shadow(color: .black.opacity(0.6), radius: 1.5))
            shadowed.fill(handles, with: .color(.white))
            shadowed.fill(pins, with: .color(Color(white: 0.55)))
            shadowed.stroke(pins, with: .color(.white), lineWidth: 2)
            shadowed.fill(chosenPin, with: .color(.black))
            shadowed.stroke(chosenPin, with: .color(.white), lineWidth: 2)
            shadowed.stroke(outline, with: .color(.white.opacity(0.8)), lineWidth: 1)
            shadowed.stroke(inner, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }
    }

    private func square(_ center: CGPoint, _ radius: Double) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}
