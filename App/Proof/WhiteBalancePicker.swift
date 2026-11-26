import AppKit
import ProofKit
import ProofUI
import SwiftUI

/// The White Balance eyedropper over the photo while it is open, as in Lightroom: a crosshair, a
/// loupe beside it of the pixels under it with the center one's RGB values, and a click that sets
/// the white balance that makes the spot neutral gray. Zoom works as usual from the keyboard and
/// the navigator, so a small gray area can be picked at any scale.
struct WhiteBalancePicker: View {
    let library: Library
    let renderer: RAWRenderer

    /// The pointer, in points from the top left, and the loupe's pixels under it.
    @State private var pointer: CGPoint?
    @State private var loupe: CGImage?

    var body: some View {
        GeometryReader { proxy in
            let sampler = WhiteBalanceSampler(library: library, renderer: renderer, size: proxy.size)
            // Esc reaches the window before the menu bar, so this holds it, as the crop tool's
            // Cancel button does, as well as the Photo menu.
            Button("Cancel White Balance Selector") { library.isPickingWhiteBalance = false }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            Color.clear
                .contentShape(Rectangle())
                .pointerStyle(.image(Image(nsImage: NSCursor.crosshair.image), hotSpot: Self.crosshairHotSpot))
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        pointer = location
                        loupe = sampler.pixels(at: location)
                    case .ended:
                        pointer = nil
                        loupe = nil
                    }
                }
                .onTapGesture { location in sampler.pick(at: location) }
                .accessibilityLabel("Photo")
                .accessibilityHint("Click something neutral gray to set the white balance")
            if let pointer, let loupe {
                LoupeView(pixels: loupe, isMeasuring: library.isAutoAdjusting)
                    .fixedSize()
                    .position(LoupePlacement.pointer.center(showing: pointer, loupe: LoupeView.size, in: proxy.size))
                    .allowsHitTesting(false)
            }
        }
    }

    private static var crosshairHotSpot: UnitPoint {
        let cursor = NSCursor.crosshair
        return UnitPoint(x: cursor.hotSpot.x / max(cursor.image.size.width, 1),
                         y: cursor.hotSpot.y / max(cursor.image.size.height, 1))
    }
}
