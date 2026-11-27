import ProofKit
import SwiftUI

/// One adjustment in the inspector: its name and value on one line, the slider below.
/// The value can be typed. Up and Down arrows in it step by `step`, by `coarseStep` with Shift
/// and by `fineStep` with Option. Double-clicking or double-tapping the name or the slider resets
/// the adjustment.
public struct AdjustmentSlider: View {
    let title: String
    /// Read by VoiceOver in place of `title` when the title leans on a heading above it, such as
    /// "Amount" under Sharpening.
    var spokenTitle: String? = nil
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

    public init(title: String, spokenTitle: String? = nil, value: Binding<Double>, range: ClosedRange<Double>,
                fineStep: Double, step: Double, coarseStep: Double, fractionDigits: Int, showsSign: Bool = false,
                unit: String = "", track: [Color] = [], position: ((Double) -> Double)? = nil,
                valueAtPosition: ((Double) -> Double)? = nil, reset: @escaping () -> Void,
                isAdjusting: @escaping (Bool) -> Void = { _ in }) {
        self.title = title
        self.spokenTitle = spokenTitle
        self._value = value
        self.range = range
        self.fineStep = fineStep
        self.step = step
        self.coarseStep = coarseStep
        self.fractionDigits = fractionDigits
        self.showsSign = showsSign
        self.unit = unit
        self.track = track
        self.position = position
        self.valueAtPosition = valueAtPosition
        self.reset = reset
        self.isAdjusting = isAdjusting
    }

    @Environment(\.doubleClickCheck) private var doubleClickCheck
    @State private var text = ""
    @FocusState private var isEditingText: Bool
    @State private var resetsOnRelease = false
    @State private var doublePress = DoublePress<Bool>(interval: DoubleClickCheck.touch.interval)
    @State private var valueAtPress: Double?
    /// Wide enough for the longest value, such as "-100" or "50000", at the person's text size.
    @ScaledMetric(relativeTo: .body) private var fieldWidth: CGFloat = 56

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .inspectorLabelStyle()
                    .onTapGesture(count: 2, perform: reset)
                    .help("Double-click to reset")
                Spacer()
                TextField(title, text: $text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .textFieldStyle(.plain)
                    .frame(width: fieldWidth)
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
                    // Apart from the slider's own name, which VoiceOver reads next.
                    .accessibilityLabel("\(spokenTitle ?? title) value")
            }
            Slider(value: Binding(get: { position?(value) ?? normalized(value) },
                                  set: { set(valueAtPosition?($0) ?? denormalized($0)) }),
                   in: 0...1) {
                Text(spokenTitle ?? title)
            } onEditingChanged: { editing in
                isAdjusting(editing)
                // The slider tracks the mouse itself, so a tap gesture on it never fires. A
                // double-click shows up as the click count of the press that starts the drag.
                // The reset waits until after the release, because the slider sends its own
                // position once more as the mouse comes up and would undo it.
                // On touch, a double-tap on the thumb is two presses that don't move it.
                if editing {
                    valueAtPress = value
                    if let isDoubleClick = doubleClickCheck.isDoubleClick {
                        resetsOnRelease = isDoubleClick()
                    } else {
                        doublePress.interval = doubleClickCheck.interval
                        resetsOnRelease = doublePress.press(true)
                    }
                } else if resetsOnRelease {
                    resetsOnRelease = false
                    Task { @MainActor in reset() }
                } else if value != valueAtPress {
                    doublePress.cancel()
                }
            }
                .labelsHidden()
                .controlSize(.small)
                .tint(track.isEmpty ? .sliderFill : .clear)
                .background(alignment: .center) { trackBackground }
                // One element in place of the system slider's, so a swipe up or down moves it by
                // a step that suits the adjustment rather than a tenth of the slider (#237).
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenTitle ?? title)
                .accessibilityValue("\(formatted(value)) \(unit)")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: swipe(up: true)
                    case .decrement: swipe(up: false)
                    @unknown default: break
                    }
                }
                .accessibilityAction(named: "Reset", reset)
        }
        .contextMenu { Button("Reset \(spokenTitle ?? title)", action: reset) }
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
        let rounded = min(max((newValue * scale).rounded() / scale, range.lowerBound), range.upperBound)
        // A touch on the thumb that doesn't move it, such as the start of a scroll, sends the
        // value it already has; setting it would add an undo step and turn As Shot into Custom.
        if formatted(rounded) != formatted(value) { value = rounded }
        text = formatted(value)
    }

    private func swipe(up: Bool) {
        set(AccessibilityMetrics.sliderValue(afterSwipe: up, from: value, in: range, step: step,
                                             position: position, valueAtPosition: valueAtPosition))
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

/// Tells a double-click or double-tap from two presses. On the Mac the system's event knows the
/// click count, which follows the person's double-click speed, so the Mac app sets one from
/// AppKit. A touch has no click count; two presses within `interval` are a double-tap.
public struct DoubleClickCheck: Sendable {
    /// The longest gap between two presses that makes them a double press.
    public var interval: TimeInterval
    /// Whether the press being handled is a double-click; `nil` where only the time between
    /// presses tells.
    public var isDoubleClick: (@MainActor @Sendable () -> Bool)?

    public init(interval: TimeInterval, isDoubleClick: (@MainActor @Sendable () -> Bool)? = nil) {
        self.interval = interval
        self.isDoubleClick = isDoubleClick
    }

    /// About UIKit's own double-tap time.
    public static let touch = DoubleClickCheck(interval: 0.35)
}

public extension EnvironmentValues {
    @Entry var doubleClickCheck = DoubleClickCheck.touch
}

public extension AdjustmentSlider {
    /// Blue to yellow and green to magenta, the way each slider shifts the photo. These show the
    /// photo's colors, so they are the one place the inspector isn't gray. Each color fades out
    /// toward the middle rather than blending into the other: opposite colors blend to gray,
    /// which reads as a dark band. The faded middle takes the panel's color in either appearance.
    static let temperatureTrack = fading(Color(red: 0.25, green: 0.45, blue: 0.95), into: Color(red: 0.95, green: 0.8, blue: 0.2))
    static let tintTrack = fading(Color(red: 0.25, green: 0.7, blue: 0.3), into: Color(red: 0.85, green: 0.3, blue: 0.8))
    /// Dark to light, the way exposure moves the photo. A soft range of grays rather than black to
    /// white, as Lightroom draws it, so the tracks don't compete with the photo.
    static let exposureTrack = [Color(white: 0.12), Color(white: 0.62)]
    /// The other tone sliders run dark to light end to end too, as Lightroom draws them.
    static let contrastTrack = exposureTrack
    /// Texture, Clarity and Dehaze run light to dark, the reverse of the tone sliders, as Lightroom draws them.
    static let textureTrack = Array(exposureTrack.reversed())
    static let clarityTrack = textureTrack
    static let dehazeTrack = textureTrack
    /// Dark to light, the way the edges move, as Lightroom draws Vignette's Amount.
    static let vignetteAmountTrack = exposureTrack
    static let highlightsTrack = exposureTrack
    static let shadowsTrack = exposureTrack
    static let whitesTrack = exposureTrack
    static let blacksTrack = exposureTrack
    /// Gray to a full spectrum, teal through blue and magenta to red, growing more colorful
    /// toward the right. A single color would suggest the slider pushes the photo toward it.
    static let vibranceTrack = [
        Color(white: 0.5),
        Color(hue: 0.47, saturation: 0.3, brightness: 0.7),
        Color(hue: 0.6, saturation: 0.6, brightness: 0.85),
        Color(hue: 0.83, saturation: 0.75, brightness: 0.9),
        Color(hue: 1, saturation: 0.85, brightness: 0.95),
    ]
    static let saturationTrack = vibranceTrack

    private static func fading(_ start: Color, into end: Color) -> [Color] {
        [start, start.opacity(0.15), end.opacity(0.15), end]
    }
}
