import ProofKit
import ProofUI
import SwiftUI

/// The row above Temperature and Tint in the iPhone Color sheet (#298): one native menu with
/// the white balance presets, which shows Custom once a slider has moved, and Pick from Photo,
/// which lowers the sheet for the eyedropper (`PhoneWhiteBalancePicker`).
struct PhoneWhiteBalanceRow: View {
    let library: Library
    let renderer: RAWRenderer?
    let openEyedropper: () -> Void

    var body: some View {
        HStack {
            Text("White Balance")
            Spacer()
            // One menu: the presets as a picker, so the chosen one has the system's checkmark,
            // and the eyedropper below them, so the row holds a single control.
            Menu {
                Picker("White Balance", selection: Binding(get: { preset }, set: choose)) {
                    ForEach(PhoneWhiteBalance.menu(showing: preset), id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                Section {
                    Button("Pick from Photo", systemImage: "eyedropper", action: openEyedropper)
                        .disabled(renderer == nil)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(preset.title)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
            }
            .accessibilityLabel("White Balance Preset")
            .accessibilityValue(preset.title)
            .accessibilityHint("Choose a preset, or pick something neutral gray in the photo")
        }
        // A slider's track sets it apart from the next one; the row has none, so it gets the
        // same room below it.
        .padding(.bottom, 8)
        // White balance starts from the camera's, read once the photo opens.
        .disabled(library.selectedEdit?.asShot == nil || library.isAutoAdjusting)
    }

    private var preset: WhiteBalancePreset { library.selectedEdit?.recipe.basic.whiteBalance ?? .asShot }

    private func choose(_ preset: WhiteBalancePreset) {
        // The sheet has no switches, so choosing turns the card on, as a slider does.
        if !library.isOn(.whiteBalance) { library.setOn(.whiteBalance, true) }
        if preset == .auto {
            guard let renderer else { return }
            Task { await library.autoWhiteBalance(with: renderer) }
        } else {
            library.changeEdit { $0.basic.choose(preset) }
        }
    }
}

/// The iPhone's eyedropper, a mode of the canvas like Crop (#298). A loupe stays on the photo,
/// starting at its center, and shows the pixels under the measured point, which a ring marks.
/// Nothing is measured until it moves, since the center may not be neutral.
/// Dragging the loupe or the ring moves it, keeping it clear of the finger; dragging elsewhere or
/// tapping moves it to the finger. Temperature and Tint follow each spot as it is measured, and
/// the navigation bar's checkmark keeps them, or Cancel returns to the white balance from before.
/// Two fingers zoom and pan, so a small gray area can be found. The iPad picks at once when a
/// finger lifts instead (`WhiteBalancePicker`): on a phone the finger covers more of the photo.
struct PhoneWhiteBalancePicker: View {
    let library: Library
    let renderer: RAWRenderer

    /// The measured point, in points from the top left; `nil` for the canvas's center until moved.
    @State private var point: CGPoint?
    /// While a drag that started on the loupe or ring moves it: from the finger to the point.
    @State private var grab: CGVector?

    /// The ring around the measured point, and how far from it a drag still grabs it, in points.
    private static let ringRadius = 14.0
    private static let grabRadius = 30.0

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let sampler = WhiteBalanceSampler(library: library, renderer: renderer, size: size)
            let pixelsPerPoint = library.zoom.viewSize.width / max(size.width, 1)
            let shown = point ?? CGPoint(x: size.width / 2, y: size.height / 2)
            let loupeCenter = LoupePlacement.touch.center(showing: shown, loupe: LoupeView.size, in: size)
            ToolTouches { event in
                switch event {
                case let .moved(start, location):
                    if grab == nil {
                        grab = grabs(start, point: shown, loupe: loupeCenter)
                            ? CGVector(dx: shown.x - start.x, dy: shown.y - start.y) : .zero
                    }
                    move(to: location, in: size, sampler: sampler)
                case let .ended(_, location):
                    move(to: location, in: size, sampler: sampler)
                    grab = nil
                case .hover:
                    break
                case let .zoom(factor, center):
                    library.zoom.zoom(by: factor, keeping: CGPoint(x: center.x * pixelsPerPoint, y: center.y * pixelsPerPoint))
                case let .pan(delta):
                    library.zoom.pan(by: CGVector(dx: delta.dx * pixelsPerPoint, dy: delta.dy * pixelsPerPoint))
                case .zoomEnded:
                    library.zoom.settle()
                    // A different part of the photo is under the loupe now.
                    if point != nil { sampler.sample(at: shown) }
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Photo")
            .accessibilityHint("Tap something neutral gray to set the white balance from it")
            Circle()
                .strokeBorder(.white, lineWidth: 1.5)
                .shadow(color: .black.opacity(0.6), radius: 1.5)
                .frame(width: Self.ringRadius * 2, height: Self.ringRadius * 2)
                .position(shown)
                .allowsHitTesting(false)
            // The values show while a spot is measured, rather than a spinner on every move.
            if let pixels = sampler.pixels(at: shown) {
                LoupeView(pixels: pixels, isMeasuring: false)
                    .fixedSize()
                    .position(loupeCenter)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Whether a drag from `start` takes hold of the loupe or the ring around the point.
    private func grabs(_ start: CGPoint, point: CGPoint, loupe: CGPoint) -> Bool {
        let half = CGSize(width: LoupeView.size.width / 2, height: LoupeView.size.height / 2)
        let onLoupe = abs(start.x - loupe.x) <= half.width && abs(start.y - loupe.y) <= half.height
        return onLoupe || hypot(start.x - point.x, start.y - point.y) <= Self.grabRadius
    }

    private func move(to location: CGPoint, in size: CGSize, sampler: WhiteBalanceSampler) {
        let offset = grab ?? .zero
        let moved = CGPoint(x: min(max(location.x + offset.dx, 0), size.width),
                            y: min(max(location.y + offset.dy, 0), size.height))
        point = moved
        sampler.sample(at: moved)
    }
}

/// The eyedropper mode's navigation bar: Cancel and a checkmark stand in for Back, Share and
/// More, as Cancel and Done do in Crop, so the mode is left only one of those two ways.
struct PhoneWhiteBalanceToolbar: ToolbarContent {
    let library: Library
    /// Brings the Color sheet back.
    let close: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") {
                library.cancelSamplingWhiteBalance()
                close()
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done", systemImage: "checkmark") {
                library.finishSamplingWhiteBalance()
                close()
            }
            .accessibilityHint("Keeps this white balance")
        }
    }
}
