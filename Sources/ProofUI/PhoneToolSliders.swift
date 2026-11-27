import ProofKit
import SwiftUI

/// The sliders of one of the iPhone editor's tool sheets (decision 0054), built from the
/// inspector's `AdjustmentSlider` with the Mac's steps and tracks. Each writes only its own value.
public struct PhoneToolSliders: View {
    let library: Library
    let adjustments: [PhoneAdjustment]

    public init(library: Library, tool: PhoneTool) {
        self.init(library: library, adjustments: tool.adjustments)
    }

    public init(library: Library, adjustments: [PhoneAdjustment]) {
        self.library = library
        self.adjustments = adjustments
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(adjustments) { adjustment in
                slider(adjustment)
            }
        }
    }

    private func slider(_ adjustment: PhoneAdjustment) -> some View {
        let style = Self.style(of: adjustment)
        // Temperature is spaced evenly in mireds, as in the inspector.
        let isTemperature = adjustment == .temperature
        let position: ((Double) -> Double)? = isTemperature ? { WhiteBalance.sliderPosition(forTemperature: $0) } : nil
        let valueAtPosition: ((Double) -> Double)? = isTemperature ? { WhiteBalance.temperature(atSliderPosition: $0) } : nil
        return AdjustmentSlider(
            title: adjustment.title, spokenTitle: adjustment.spokenTitle, value: binding(for: adjustment),
            range: adjustment.range, fineStep: style.fine, step: style.step, coarseStep: style.coarse,
            fractionDigits: style.digits, showsSign: style.showsSign, unit: style.unit, track: style.track,
            position: position, valueAtPosition: valueAtPosition,
            reset: { library.changeEdit { adjustment.reset(in: &$0) } },
            isAdjusting: { library.isAdjusting = $0 })
            // White balance and sharpness start from the camera's, read once the photo opens.
            .disabled(value(of: adjustment) == nil)
            // Kept in view, dimmed, where it changes nothing as the edit stands.
            .disabled(library.selectedEdit.map { adjustment.isInactive(in: $0.recipe, camera: $0.cameraDetail) } ?? false)
    }

    private func value(of adjustment: PhoneAdjustment) -> Double? {
        guard let edit = library.selectedEdit else { return nil }
        return adjustment.value(in: edit.recipe, asShot: edit.asShot, camera: edit.cameraDetail)
    }

    /// Reads the edit on each call: the slider reads the value back right after setting it.
    private func binding(for adjustment: PhoneAdjustment) -> Binding<Double> {
        Binding(get: { value(of: adjustment) ?? 0 }, set: { newValue in
            // The sheet has no switches, so a change to a card switched off on the Mac switches
            // it on first, as choosing a look does.
            if !library.isOn(adjustment.group) { library.setOn(adjustment.group, true) }
            library.changeEdit { adjustment.set(newValue, in: &$0) }
        })
    }

    private struct Style {
        var fine = 1.0, step = 1.0, coarse = 10.0
        var digits = 0
        var showsSign = true
        var unit = ""
        var track: [Color] = []
    }

    /// The steps, sign and track each slider has in the inspector.
    private static func style(of adjustment: PhoneAdjustment) -> Style {
        switch adjustment {
        case .exposure: Style(fine: 0.01, step: 0.1, coarse: 1, digits: 2, unit: "stops", track: AdjustmentSlider.exposureTrack)
        case .contrast: Style(track: AdjustmentSlider.contrastTrack)
        case .highlights: Style(track: AdjustmentSlider.highlightsTrack)
        case .shadows: Style(track: AdjustmentSlider.shadowsTrack)
        case .whites: Style(track: AdjustmentSlider.whitesTrack)
        case .blacks: Style(track: AdjustmentSlider.blacksTrack)
        case .temperature: Style(step: 10, coarse: 100, showsSign: false, unit: "Kelvin", track: AdjustmentSlider.temperatureTrack)
        case .tint: Style(track: AdjustmentSlider.tintTrack)
        case .saturation: Style(track: AdjustmentSlider.saturationTrack)
        case .vibrance: Style(track: AdjustmentSlider.vibranceTrack)
        case .mixRed: Style(track: SelectiveColorCard.brightnessTrack(hue: 0))
        case .mixGreen: Style(track: SelectiveColorCard.brightnessTrack(hue: 120))
        case .mixBlue: Style(track: SelectiveColorCard.brightnessTrack(hue: 240))
        case let .selectiveHue(range): Style(track: SelectiveColorCard.hueTrack(range))
        case let .selectiveSaturation(range): Style(track: SelectiveColorCard.saturationTrack(range))
        case let .selectiveBrightness(range): Style(track: SelectiveColorCard.brightnessTrack(range))
        case .texture: Style(track: AdjustmentSlider.textureTrack)
        case .clarity: Style(track: AdjustmentSlider.clarityTrack)
        case .dehaze: Style(track: AdjustmentSlider.dehazeTrack)
        case .sharpness, .noiseReduction, .noiseReductionDetail, .colorNoiseReduction: Style(showsSign: false)
        case .vignette: Style(track: AdjustmentSlider.vignetteAmountTrack)
        case .vignetteRoundness: Style()
        case .grain, .grainSize, .grainRoughness, .halation, .halationSize, .bloom, .bloomSize, .vignetteMidpoint, .vignetteFeather: Style(showsSign: false)
        }
    }
}
