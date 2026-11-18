import AppKit
import ProofKit
import SwiftUI

/// The Masks tool on the photo. Every mask shows a pin: click one to select its mask, and drag a
/// gradient's or brush mask's pin to move it. The selected linear gradient shows three lines:
/// drag the middle one to turn it and an outer one to change the fade. The selected radial
/// gradient shows its ellipse: drag inside to move it, the handles on its sides to size it and
/// the one above it to turn it (Shift steps by 15°). On a selected brush mask, dragging paints,
/// and erases with Option held or Erase chosen. Delete removes the selected mask, O shows it in
/// red, [ and ] size the brush, and Return, Esc and M close the tool. Pinching zooms and dragging
/// with the space bar held pans, as on the canvas. A temporary tool, so it may sit on the photo.
struct MaskOverlay: View {
    let library: Library
    let zoom: CanvasZoom
    /// The crop the canvas shows.
    let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space masks are placed in.
    let photoSize: CGSize

    private enum Part: Equatable {
        case linearStart, linearEnd, linearTurn
        case radialWidth, radialHeight, radialTurn, radialInside
        /// A mask's pin, by its place in `layers`.
        case pin(Int)
    }

    /// What a drag does, with what it started from.
    private enum Drag {
        case moving(Part, layer: Int, original: Mask, start: CGPoint)
        case painting(last: CGPoint)
        case panning(last: CGSize)
    }

    @State private var pointer: CGPoint?
    @State private var hovered: Part?
    @State private var drag: Drag?
    @State private var isSpaceDown = false
    @State private var pinched: CGFloat?
    @State private var keyMonitor: Any?

    /// How near a handle or line a press must be, in points.
    private static let reach = 7.0
    private static let pinRadius = 5.0
    private static let sizeStep = 1.15

    var body: some View {
        GeometryReader { geometry in
            let photo = photoRect(in: geometry.size)
            let _ = updateFrame(geometry.frame(in: .global))
            let layers = library.layers
            Canvas { context, _ in
                var thin = Path(), bold = Path(), dashed = Path(), handles = Path(), pins = Path(), chosenPin = Path()
                for (index, layer) in layers.enumerated() {
                    guard let pin = pinPoint(of: layer.mask, photo: photo) else { continue }
                    if index == library.selectedLayer {
                        chosenPin.addEllipse(in: square(pin, Self.pinRadius))
                    } else {
                        pins.addEllipse(in: square(pin, Self.pinRadius))
                    }
                }
                if let layer = library.shownLayer {
                    switch layer.mask.shape {
                    case let .linear(gradient):
                        let lines = linearLines(gradient, photo: photo)
                        for (point, isMiddle) in [(lines.start, false), (lines.middle, true), (lines.end, false)] {
                            var line = Path()
                            line.move(to: CGPoint(x: point.x - lines.across.dx * 5000, y: point.y - lines.across.dy * 5000))
                            line.addLine(to: CGPoint(x: point.x + lines.across.dx * 5000, y: point.y + lines.across.dy * 5000))
                            if isMiddle { bold.addPath(line) } else { thin.addPath(line) }
                        }
                    case let .radial(gradient):
                        let shape = radialShape(gradient, photo: photo)
                        bold.addPath(shape.outline)
                        dashed.addPath(shape.inner)
                        for handle in [shape.width, shape.height] { handles.addRect(square(handle, 4)) }
                        handles.addEllipse(in: square(shape.turn, 4))
                        thin.move(to: shape.height)
                        thin.addLine(to: shape.turn)
                    case .brush, .subject, .unknown:
                        break
                    }
                }
                // The brush's size at the pointer, and where its feather starts.
                var brush = Path(), brushInner = Path()
                if isPainting, let pointer, hovered == nil || isDrawingStroke, !isSpaceDown, photo.contains(pointer) {
                    let radius = shownRadius(library.nextStroke.radius, photo: photo)
                    brush.addEllipse(in: square(pointer, radius))
                    let inner = radius * (1 - library.nextStroke.feather / 100)
                    if inner > 1 { brushInner.addEllipse(in: square(pointer, inner)) }
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
                // Gray pins with a white ring; the selected mask's is black.
                shadowed.fill(pins, with: .color(Color(white: 0.55)))
                shadowed.stroke(pins, with: .color(.white), lineWidth: 2)
                shadowed.fill(chosenPin, with: .color(.black))
                shadowed.stroke(chosenPin, with: .color(.white), lineWidth: 2)
                shadowed.stroke(brush, with: .color(.white.opacity(0.8)), lineWidth: 1)
                shadowed.stroke(brushInner, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .contentShape(Rectangle())
            // Not focusable: the keys are watched below, and taking focus would cost the first
            // press after a click in the inspector.
            .onAppear {
                zoom.hidesPanPointer = true
                watchKeys()
            }
            .onDisappear {
                zoom.hidesPanPointer = false
                if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
                keyMonitor = nil
            }
            .accessibilityElement()
            .accessibilityLabel("Photo")
            .accessibilityValue(layers.count == 1 ? "1 mask" : "\(layers.count) masks")
            .accessibilityHint(isPainting ? "Drag to paint the mask" : "")
            .pointerStyle(pointerStyle(photo: photo))
            .onContinuousHover { phase in
                if case let .active(location) = phase {
                    pointer = location
                    hovered = part(at: location, photo: photo)
                } else {
                    pointer = nil
                    hovered = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in changed(value, photo: photo, viewSize: geometry.size) }
                    .onEnded { value in ended(value, photo: photo) })
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
        // Return and Esc close the tool, wherever the keyboard focus is, as the menu's M does.
        .background {
            Group {
                Button("Done with Masks") { library.finishMasking() }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Close Masks") { library.finishMasking() }
                    .keyboardShortcut(.cancelAction)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
    }

    // MARK: Gestures

    private var isPainting: Bool {
        guard case .brush = library.shownLayer?.mask.shape else { return false }
        return true
    }

    private var isDrawingStroke: Bool {
        if case .painting = drag { return true }
        return false
    }

    private func changed(_ value: DragGesture.Value, photo: CGRect, viewSize: CGSize) {
        if case let .panning(last) = drag {
            pan(value.translation, last: last, viewSize: viewSize)
            return
        }
        if drag == nil {
            if isSpaceDown {
                drag = .panning(last: .zero)
                pan(value.translation, last: .zero, viewSize: viewSize)
                return
            }
            guard let start = point(at: value.startLocation, photo: photo) else { return }
            switch part(at: value.startLocation, photo: photo) {
            case let .pin(index):
                library.selectLayer(index)
                drag = .moving(.pin(index), layer: index, original: library.layers[index].mask, start: start)
            case let pressed?:
                guard let index = library.selectedLayer, let layer = library.shownLayer else { return }
                drag = .moving(pressed, layer: index, original: layer.mask, start: start)
            case nil:
                guard isPainting, photo.contains(value.startLocation) else { return }
                library.isAdjusting = true
                let erasing = library.isErasing != NSEvent.modifierFlags.contains(.option)
                library.startStroke(at: start, erasing: erasing)
                drag = .painting(last: start)
                return
            }
        }
        guard let current = point(at: value.location, photo: photo) else { return }
        switch drag {
        case let .moving(part, layer, original, start):
            guard hypot(value.translation.width, value.translation.height) >= 2 else { return }
            library.isAdjusting = true
            let moved = Self.moved(original, part: part, from: start, to: current, photoSize: photoSize)
            library.changeLayer(at: layer) { $0.mask = moved }
        case let .painting(last):
            // Points closer than a quarter of the brush add nothing a smooth stroke needs.
            let long = max(photoSize.width, photoSize.height)
            let distance = hypot((current.x - last.x) * photoSize.width, (current.y - last.y) * photoSize.height)
            guard distance >= library.nextStroke.radius * long / 4 else { return }
            library.continueStroke(to: current)
            drag = .painting(last: current)
        case .panning, nil:
            break
        }
    }

    private func ended(_ value: DragGesture.Value, photo: CGRect) {
        defer { drag = nil }
        switch drag {
        case let .painting(last):
            if let end = point(at: value.location, photo: photo), end != last { library.continueStroke(to: end) }
            library.isAdjusting = false
        case .moving:
            library.isAdjusting = false
        case .panning, nil:
            break
        }
    }

    private func pan(_ translation: CGSize, last: CGSize, viewSize: CGSize) {
        let pixelsPerPoint = zoom.viewSize.width / max(viewSize.width, 1)
        zoom.pan(by: CGVector(dx: (translation.width - last.width) * pixelsPerPoint,
                              dy: (translation.height - last.height) * pixelsPerPoint))
        drag = .panning(last: translation)
    }

    /// `mask` with `part` dragged from `start` to `end`, both in mask coordinates.
    private static func moved(_ mask: Mask, part: Part, from start: CGPoint, to end: CGPoint, photoSize: CGSize) -> Mask {
        var mask = mask
        let shift = CGPoint(x: end.x - start.x, y: end.y - start.y)
        func shifted(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x + shift.x, y: point.y + shift.y) }
        let long = max(photoSize.width, photoSize.height, 1)
        switch mask.shape {
        case var .linear(gradient):
            switch part {
            case .linearStart: gradient.start = shifted(gradient.start)
            case .linearEnd: gradient.end = shifted(gradient.end)
            case .linearTurn:
                // Both ends turn around the middle, in pixels with y down so the turn is true.
                let middle = CGPoint(x: (gradient.startX + gradient.endX) / 2, y: (gradient.startY + gradient.endY) / 2)
                let from = atan2((start.y - middle.y) * photoSize.height, (start.x - middle.x) * photoSize.width)
                let to = atan2((end.y - middle.y) * photoSize.height, (end.x - middle.x) * photoSize.width)
                let angle = to - from
                func turned(_ point: CGPoint) -> CGPoint {
                    let x = (point.x - middle.x) * photoSize.width, y = (point.y - middle.y) * photoSize.height
                    return CGPoint(x: middle.x + (x * cos(angle) - y * sin(angle)) / photoSize.width,
                                   y: middle.y + (x * sin(angle) + y * cos(angle)) / photoSize.height)
                }
                gradient.start = turned(gradient.start)
                gradient.end = turned(gradient.end)
            default:
                gradient.start = shifted(gradient.start)
                gradient.end = shifted(gradient.end)
            }
            mask.shape = .linear(gradient)
        case var .radial(gradient):
            // In pixels of the photo, y down, so the ellipse's axes are square to each other.
            let dx = (end.x - gradient.centerX) * photoSize.width, dy = (end.y - gradient.centerY) * photoSize.height
            let angle = gradient.angle * .pi / 180
            let range = RadialMask.radiusRange
            switch part {
            case .radialWidth:
                gradient.radiusX = min(max(abs(dx * cos(angle) + dy * sin(angle)) / long, range.lowerBound), range.upperBound)
            case .radialHeight:
                gradient.radiusY = min(max(abs(-dx * sin(angle) + dy * cos(angle)) / long, range.lowerBound), range.upperBound)
            case .radialTurn:
                // The handle sits above the center when the angle is 0.
                var degrees = atan2(dx, -dy) * 180 / .pi
                if NSEvent.modifierFlags.contains(.shift) { degrees = (degrees / 15).rounded() * 15 }
                gradient.angle = degrees
            default:
                gradient.center = shifted(gradient.center)
            }
            mask.shape = .radial(gradient)
        case var .brush(brush):
            // Only its pin moves a brush mask, and every stroke moves with it.
            guard case .pin = part else { break }
            for index in brush.strokes.indices {
                brush.strokes[index].points = brush.strokes[index].points.enumerated().map { offset, value in
                    value + (offset.isMultiple(of: 2) ? shift.x : shift.y)
                }
            }
            mask.shape = .brush(brush)
        case .subject, .unknown:
            break
        }
        return mask
    }

    // MARK: Hit testing

    /// Pins first, then the selected mask's handles and lines, then the inside of its ellipse.
    private func part(at location: CGPoint, photo: CGRect) -> Part? {
        func near(_ point: CGPoint, _ distance: Double = Self.reach) -> Bool {
            hypot(location.x - point.x, location.y - point.y) <= distance
        }
        let layers = library.layers
        // The selected mask's pin first, then the topmost of the others.
        let order = (library.selectedLayer.map { [$0] } ?? []) + layers.indices.reversed().filter { $0 != library.selectedLayer }
        for index in order where layers.indices.contains(index) {
            if let pin = pinPoint(of: layers[index].mask, photo: photo), near(pin, Self.pinRadius + 3) { return .pin(index) }
        }
        guard let layer = library.shownLayer else { return nil }
        switch layer.mask.shape {
        case let .linear(gradient):
            let lines = linearLines(gradient, photo: photo)
            // How far along the gradient's direction the location is from each line.
            func off(_ point: CGPoint) -> Double {
                abs((location.x - point.x) * lines.across.dy - (location.y - point.y) * lines.across.dx)
            }
            guard photo.contains(location) else { return nil }
            if off(lines.middle) <= Self.reach { return .linearTurn }
            if off(lines.start) <= Self.reach { return .linearStart }
            if off(lines.end) <= Self.reach { return .linearEnd }
        case let .radial(gradient):
            let shape = radialShape(gradient, photo: photo)
            if near(shape.turn) { return .radialTurn }
            if near(shape.width) { return .radialWidth }
            if near(shape.height) { return .radialHeight }
            if shape.outline.contains(location) { return .radialInside }
        case .brush, .subject, .unknown:
            break
        }
        return nil
    }

    private func pointerStyle(photo: CGRect) -> PointerStyle {
        if case .panning = drag { return .grabActive }
        if isSpaceDown { return .grabIdle }
        let part: Part?
        if case let .moving(moving, _, _, _) = drag { part = moving } else { part = hovered }
        switch part {
        case let .pin(index):
            if index != library.selectedLayer, drag == nil { return .link }
            return drag == nil ? .grabIdle : .grabActive
        case .radialInside:
            return drag == nil ? .grabIdle : .grabActive
        case .linearTurn, .radialTurn:
            // The crop tool's, so turning looks the same everywhere.
            return .image(Image(nsImage: RotateCursor.image(for: .topRight)), hotSpot: .center)
        case .linearStart, .linearEnd:
            guard case let .linear(gradient) = library.shownLayer?.mask.shape else { return .default }
            let lines = linearLines(gradient, photo: photo)
            // An outer line moves square to itself.
            return Self.resizePointer(dx: lines.across.dy, dy: -lines.across.dx)
        case .radialWidth, .radialHeight:
            guard case let .radial(gradient) = library.shownLayer?.mask.shape else { return .default }
            let shape = radialShape(gradient, photo: photo)
            let handle = part == .radialWidth ? shape.width : shape.height
            return Self.resizePointer(dx: handle.x - shape.center.x, dy: handle.y - shape.center.y)
        case nil:
            return isPainting ? .rectSelection : .default
        }
    }

    /// The resize pointer closest to dragging along (`dx`, `dy`), with y down.
    private static func resizePointer(dx: Double, dy: Double) -> PointerStyle {
        var degrees = (atan2(dy, dx) * 180 / .pi).truncatingRemainder(dividingBy: 180)
        if degrees < 0 { degrees += 180 }
        switch degrees {
        case ..<22.5, 157.5...: return .columnResize
        case ..<67.5: return .frameResize(position: .bottomTrailing)
        case ..<112.5: return .rowResize
        default: return .frameResize(position: .bottomLeading)
        }
    }

    // MARK: Keys

    /// Follows the tool's keys while it is open, wherever the keyboard focus is, as long as no
    /// text is being typed.
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
                guard let index = library.selectedLayer else { return event }
                if event.type == .keyDown { library.removeLayer(at: index) }
                return nil
            default:
                guard let key = event.charactersIgnoringModifiers else { return event }
                switch key {
                case "o":
                    if event.type == .keyDown { library.showsMaskOverlay.toggle() }
                    return nil
                case "[", "]":
                    if event.type == .keyDown {
                        let factor = key == "]" ? Self.sizeStep : 1 / Self.sizeStep
                        let range = BrushStroke.radiusRange
                        library.nextStroke.radius = min(max(library.nextStroke.radius * factor, range.lowerBound), range.upperBound)
                    }
                    return nil
                default:
                    return event
                }
            }
        }
    }

    /// Pans with a two-finger scroll, or zooms with ⌘-scroll, as the canvas under the tool does.
    /// Returns whether it used the event.
    private func scroll(_ event: NSEvent) -> Bool {
        guard let window = event.window, let content = window.contentView, zoom.isEnabled, frame.width > 0 else { return false }
        let location = CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y)
        guard frame.contains(location) else { return false }
        let pixelsPerPoint = zoom.viewSize.width / frame.width
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

    // MARK: Geometry

    /// The three lines' points on the canvas, and the direction they run in, a unit vector.
    private func linearLines(_ gradient: LinearMask, photo: CGRect) -> (start: CGPoint, middle: CGPoint, end: CGPoint, across: CGVector) {
        let start = shown(gradient.start, photo: photo), end = shown(gradient.end, photo: photo)
        let middle = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let length = max(hypot(end.x - start.x, end.y - start.y), 0.001)
        return (start, middle, end, CGVector(dx: -(end.y - start.y) / length, dy: (end.x - start.x) / length))
    }

    /// The ellipse and where its feather starts, as paths on the canvas, with its handles: on the
    /// end of its width axis, on the top of its height axis, and above that, the turning handle.
    private func radialShape(_ gradient: RadialMask, photo: CGRect)
        -> (outline: Path, inner: Path, center: CGPoint, width: CGPoint, height: CGPoint, turn: CGPoint) {
        // Points of the ellipse in mask coordinates, from its angle and radii in pixels with y down.
        let long = max(photoSize.width, photoSize.height, 1)
        let angle = gradient.angle * .pi / 180
        let rx = gradient.radiusX * long, ry = gradient.radiusY * long
        func at(_ t: Double, scale: Double = 1) -> CGPoint {
            let x = rx * scale * cos(t), y = ry * scale * sin(t)
            let dx = x * cos(angle) - y * sin(angle), dy = x * sin(angle) + y * cos(angle)
            return shown(CGPoint(x: gradient.centerX + dx / photoSize.width, y: gradient.centerY + dy / photoSize.height),
                         photo: photo)
        }
        func ellipse(scale: Double) -> Path {
            var path = Path()
            path.addLines((0...72).map { at(Double($0) / 72 * 2 * .pi, scale: scale) })
            path.closeSubpath()
            return path
        }
        let center = shown(gradient.center, photo: photo)
        let top = at(-.pi / 2)
        let up = CGVector(dx: top.x - center.x, dy: top.y - center.y)
        let length = max(hypot(up.dx, up.dy), 0.001)
        let feather = min(max(gradient.feather, 0), 100) / 100
        return (ellipse(scale: 1), feather > 0.02 ? ellipse(scale: 1 - feather) : Path(), center, at(0), top,
                CGPoint(x: top.x + up.dx / length * 22, y: top.y + up.dy / length * 22))
    }

    /// Where a mask's pin goes: a linear gradient's middle, a radial one's center, where a brush
    /// mask's first stroke starts, or the middle of the subject.
    private func pinPoint(of mask: Mask, photo: CGRect) -> CGPoint? {
        switch mask.shape {
        case let .linear(gradient):
            shown(CGPoint(x: (gradient.startX + gradient.endX) / 2, y: (gradient.startY + gradient.endY) / 2), photo: photo)
        case let .radial(gradient):
            shown(gradient.center, photo: photo)
        case let .brush(brush):
            brush.strokes.first { !$0.erases }?.path.first.map { shown($0, photo: photo) }
        case let .subject(subject):
            subject.center.map { shown($0, photo: photo) }
        case .unknown:
            nil
        }
    }

    private func square(_ center: CGPoint, _ radius: Double) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }

    /// The photo's rectangle on the canvas, in points.
    private func photoRect(in size: CGSize) -> CGRect {
        guard size.width > 0, zoom.viewSize.width > 0, zoom.photoSize.width > 0 else { return .zero }
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

    /// The brush's radius on the canvas, in points.
    private func shownRadius(_ radius: Double, photo: CGRect) -> Double {
        guard zoom.photoSize.width > 0 else { return 4 }
        return max(radius * max(photoSize.width, photoSize.height) * photo.width / zoom.photoSize.width, 2)
    }

    /// The point of the uncropped photo, from 0 to 1, that shows at `location`. Masks may reach
    /// past the photo, so it isn't kept on it; `nil` before the photo is laid out.
    private func point(at location: CGPoint, photo: CGRect) -> CGPoint? {
        guard photo.width > 0, photo.height > 0 else { return nil }
        let shown = CGPoint(x: (location.x - photo.minX) / photo.width, y: (location.y - photo.minY) / photo.height)
        return crop?.photoPoint(of: shown, photoSize: photoSize) ?? shown
    }
}
