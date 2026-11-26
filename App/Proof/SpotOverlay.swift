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

    @State private var pointer: CGPoint?
    @State private var hovered: SpotPart?
    @State private var press = SpotPress()
    @FocusState private var isFocused: Bool
    /// The space bar is held, so a drag pans instead of placing or moving a spot.
    @State private var isSpaceDown = false
    /// The drag's translation when it last panned, while a drag is panning.
    @State private var panned: CGSize?
    /// The pinch's magnification when it last zoomed, while pinching.
    @State private var pinched: CGFloat?
    @State private var keyMonitor: Any?

    /// How much [ and ] change the size by.
    private static let sizeStep = 1.15

    var body: some View {
        GeometryReader { geometry in
            let layout = SpotLayout(size: geometry.size, zoom: zoom, crop: crop, photoSize: photoSize)
            // Where the tool is in the window, for scrolling, which the window's monitor sees.
            let _ = updateFrame(geometry.frame(in: .global))
            let spots = library.selectedEdit?.recipe.spots ?? []
            let selected = library.selectedSpot.flatMap { spots.indices.contains($0) ? $0 : nil }
            SpotMarks(library: library, layout: layout,
                      brush: hovered == nil && !press.isActive && panned == nil && !isSpaceDown ? pointer : nil,
                      hovered: hovered, isPainting: press.painted != nil)
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
                    hovered = layout.part(at: location, spots: spots, selected: selected)
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
                        if press.moved(from: value.startLocation, to: value.location, layout: layout, library: library) {
                            isFocused = true
                        }
                    }
                    .onEnded { value in
                        if panned != nil {
                            panned = nil
                            return
                        }
                        if press.ended(at: value.location, distance: hypot(value.translation.width, value.translation.height),
                                       layout: layout, library: library, renderer: renderer) {
                            isFocused = true
                        }
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
        if panned != nil || press.isActive { return .grabActive }
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
}
