import SwiftUI

/// One adjustment in the inspector: its name and value on one line, the slider below.
/// The value can be typed. Up and Down arrows in it step by `step`, by `coarseStep` with Shift
/// and by `fineStep` with Option. Double-clicking the name resets the adjustment.
struct AdjustmentSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let fineStep: Double
    let step: Double
    let coarseStep: Double
    /// Digits after the decimal point, for display and for values set by the slider.
    let fractionDigits: Int
    /// Shows a plus sign on positive values, for adjustments centered on zero.
    var showsSign = false
    /// Read by VoiceOver after the value, such as "stops" or "Kelvin".
    var unit = ""
    /// Colors along the slider from left to right, showing what the adjustment does to the photo.
    var track: [Color] = []
    /// Maps a value to the slider's 0–1 position and back. Linear when `nil`.
    var position: ((Double) -> Double)?
    var valueAtPosition: ((Double) -> Double)?
    let reset: () -> Void
    /// Called with `true` when a drag starts and `false` when it ends.
    var isAdjusting: (Bool) -> Void = { _ in }

    @State private var text = ""
    @FocusState private var isEditingText: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .onTapGesture(count: 2, perform: reset)
                    .help("Double-click to reset")
                Spacer()
                TextField(title, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .textFieldStyle(.plain)
                    .frame(width: 56)
                    .focused($isEditingText)
                    .onSubmit(commitText)
                    .onChange(of: isEditingText) { if !isEditingText { commitText() } }
                    .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                        let amount = press.modifiers.contains(.shift) ? coarseStep
                            : press.modifiers.contains(.option) ? fineStep : step
                        set((Double(text) ?? value) + (press.key == .upArrow ? amount : -amount))
                        return .handled
                    }
                    .help("Up and Down arrows step by \(formatted(step)). Shift steps by \(formatted(coarseStep)), Option by \(formatted(fineStep)).")
                    .accessibilityLabel(title)
            }
            Slider(value: Binding(get: { position?(value) ?? normalized(value) },
                                  set: { set(valueAtPosition?($0) ?? denormalized($0)) }),
                   in: 0...1) {
                Text(title)
            } onEditingChanged: { isAdjusting($0) }
                .labelsHidden()
                .controlSize(.small)
                .tint(track.isEmpty ? nil : .clear)
                .background(alignment: .center) { trackBackground }
                .accessibilityValue("\(formatted(value)) \(unit)")
                .accessibilityAction(named: "Reset", reset)
        }
        .contextMenu { Button("Reset \(title)", action: reset) }
        .onAppear { text = formatted(value) }
        .onChange(of: value) { if !isEditingText || text != formatted(value) { text = formatted(value) } }
    }

    /// Colors the slider's groove to show what the adjustment does. The slider's own fill is
    /// hidden over it so the colors show from end to end.
    @ViewBuilder private var trackBackground: some View {
        if !track.isEmpty {
            Capsule()
                .fill(LinearGradient(colors: track, startPoint: .leading, endPoint: .trailing))
                // A hairline edge keeps a light end visible on a light panel.
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
                .frame(height: 4)
                .padding(.horizontal, 2)
                .accessibilityHidden(true)
        }
    }

    private func normalized(_ value: Double) -> Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    private func denormalized(_ position: Double) -> Double {
        range.lowerBound + position * (range.upperBound - range.lowerBound)
    }

    /// Sets a value from any of the controls, rounded to what is shown and kept in range.
    private func set(_ newValue: Double) {
        let scale = pow(10, Double(fractionDigits))
        value = min(max((newValue * scale).rounded() / scale, range.lowerBound), range.upperBound)
        text = formatted(value)
    }

    private func commitText() {
        let typed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "+", with: "")
        // Leaving the field without a change mustn't set the value: for white balance that
        // would turn As Shot into Custom.
        if let number = Double(typed), formatted(number) != formatted(value) { set(number) } else { text = formatted(value) }
    }

    private func formatted(_ number: Double) -> String {
        // Adding zero turns −0, which a small negative value rounds to, into 0.
        let scale = pow(10, Double(fractionDigits))
        let rounded = (number * scale).rounded() / scale + 0
        let string = String(format: "%.\(fractionDigits)f", rounded)
        return showsSign && rounded > 0 ? "+" + string : string
    }
}
