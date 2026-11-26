import AppKit
import ProofKit
import ProofUI
import SwiftUI

/// The Masks tool on the photo. Every mask shows a pin: click one to select its mask, and drag a
/// gradient's or brush mask's pin to move it. The selected linear gradient shows three lines:
/// drag the middle one to turn it and an outer one to change the fade. The selected radial
/// gradient shows its ellipse: drag inside to move it, the handles on its sides to size it and
/// the one above it to turn it (Shift steps by 15°). On a selected brush mask, dragging paints,
/// and erases with Option held or Erase chosen. Delete removes the selected mask, O shows it in
/// red, [ and ] size the brush, and Return, Esc and M close the tool. Pinching zooms and dragging
/// with the space bar held pans, as on the canvas. `MaskLayout`, `MaskPress` and `MaskMarks`,
/// shared with iOS, place, edit and draw the masks. A temporary tool, so it may sit on the photo.
struct MaskOverlay: View {
    let library: Library
    let zoom: CanvasZoom
    /// The crop the canvas shows.
    let crop: Crop?
    /// The photo as the camera oriented it, in pixels: the space masks are placed in.
    let photoSize: CGSize

    @State private var pointer: CGPoint?
    @State private var hovered: MaskPart?
    @State private var press = MaskPress()
    /// The drag's translation when it last panned, while a drag is panning.
    @State private var panned: CGSize?
    @State private var isSpaceDown = false
    @State private var pinched: CGFloat?
    @State private var keyMonitor: Any?

    private static let sizeStep = 1.15

    var body: some View {
        GeometryReader { geometry in
            let layout = MaskLayout(size: geometry.size, zoom: zoom, crop: crop, photoSize: photoSize)
            let _ = updateFrame(geometry.frame(in: .global))
            let layers = library.layers
            let paints = MaskPress.paints(library)
            // The brush's size at the pointer, while it would paint.
            let brush = paints && (hovered == nil || press.isPainting) && !isSpaceDown && panned == nil ? pointer : nil
            MaskMarks(library: library, layout: layout, brush: brush)
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
            .accessibilityHint(paints ? "Drag to paint the mask" : "")
            .pointerStyle(pointerStyle(layout: layout))
            .onContinuousHover { phase in
                if case let .active(location) = phase {
                    pointer = location
                    hovered = layout.part(at: location, library: library)
                } else {
                    pointer = nil
                    hovered = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if panned != nil || (!press.isActive && isSpaceDown) {
                            let last = panned ?? .zero
                            let pixelsPerPoint = zoom.viewSize.width / max(geometry.size.width, 1)
                            zoom.pan(by: CGVector(dx: (value.translation.width - last.width) * pixelsPerPoint,
                                                  dy: (value.translation.height - last.height) * pixelsPerPoint))
                            panned = value.translation
                            return
                        }
                        let flags = NSEvent.modifierFlags
                        press.moved(from: value.startLocation, to: value.location, layout: layout, library: library,
                                    flipsErasing: flags.contains(.option), snapsAngle: flags.contains(.shift))
                    }
                    .onEnded { value in
                        if panned != nil {
                            panned = nil
                            return
                        }
                        press.ended(at: value.location, layout: layout, library: library)
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

    // MARK: Pointer

    private func pointerStyle(layout: MaskLayout) -> PointerStyle {
        if panned != nil { return .grabActive }
        if isSpaceDown { return .grabIdle }
        let part = press.movingPart ?? hovered
        let isDragging = press.isActive
        switch part {
        case let .pin(index):
            if index != library.selectedLayer, !isDragging { return .link }
            return isDragging ? .grabActive : .grabIdle
        case .radialInside:
            return isDragging ? .grabActive : .grabIdle
        case .linearTurn, .radialTurn:
            // The crop tool's, so turning looks the same everywhere.
            return .image(Image(nsImage: RotateCursor.image(for: .topRight)), hotSpot: .center)
        case .linearStart, .linearEnd:
            guard case let .linear(gradient) = library.shownLayer?.mask.shape else { return .default }
            let lines = layout.linearLines(gradient)
            // An outer line moves square to itself.
            return Self.resizePointer(dx: lines.across.dy, dy: -lines.across.dx)
        case .radialWidth, .radialHeight:
            guard case let .radial(gradient) = library.shownLayer?.mask.shape else { return .default }
            let shape = layout.radialShape(gradient)
            let handle = part == .radialWidth ? shape.width : shape.height
            return Self.resizePointer(dx: handle.x - shape.center.x, dy: handle.y - shape.center.y)
        case nil:
            return MaskPress.paints(library) ? .rectSelection : .default
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
}
