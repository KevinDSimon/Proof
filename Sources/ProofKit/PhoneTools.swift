/// The tools of the iPhone editor's bottom toolbar, in its order (decision 0054). Each of Looks,
/// Light, Color and Finish opens a sheet over the same recipe the Mac edits; Crop opens the crop
/// tool. Adjustments without a control here, such as curves or masks, are kept as they are.
public enum PhoneTool: String, CaseIterable, Identifiable, Sendable {
    case looks, light, color, finish, crop

    public var id: Self { self }

    public var title: String {
        switch self {
        case .looks: "Looks"
        case .light: "Light"
        case .color: "Color"
        case .finish: "Finish"
        case .crop: "Crop"
        }
    }

    /// The SF Symbol for the toolbar button.
    public var systemImage: String {
        switch self {
        case .looks: "camera.filters"
        case .light: "sun.max"
        case .color: "drop.halffull"
        case .finish: "circle.dotted"
        case .crop: "crop"
        }
    }

    /// The segments of the tool's sheet, the Mac's card names, for a tool whose sheet has
    /// more than fits one list. Empty for a sheet of one list.
    public var sections: [PhoneToolSection] {
        switch self {
        case .color: [.basic, .selectiveColor]
        case .finish: [.detail, .effects]
        default: []
        }
    }

    /// Every slider the tool's sheet can show, in order. A tool with segments shows them one
    /// segment at a time. Looks shows the LUT library instead, and Crop has no sheet.
    public var adjustments: [PhoneAdjustment] {
        switch self {
        case .looks, .crop: []
        case .light: [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]
        case .color, .finish: sections.flatMap(\.adjustments)
        }
    }

    /// Whether the tool opens a sheet.
    public var hasSheet: Bool { self != .crop }

    /// Whether the sheet's top bar has Auto, which sets the tool's sliders from the photo, as the
    /// Mac's Basic card does for its Tone sliders.
    public var hasAuto: Bool { self == .light }

    /// Whether the sheet opens at the medium height rather than the compact one: the segments and
    /// rows above the sliders leave no room for one at the compact height.
    public var opensAtMediumHeight: Bool { !sections.isEmpty }
}

/// One segment of an iPhone tool sheet, named for the Mac's card it comes from.
public enum PhoneToolSection: String, CaseIterable, Identifiable, Sendable {
    case basic, selectiveColor, detail, effects

    public var id: Self { self }

    public var title: String {
        switch self {
        case .basic: "Basic"
        case .selectiveColor: "Selective Color"
        case .detail: "Detail"
        case .effects: "Effects"
        }
    }

    /// Every slider the segment can show, for Reset.
    public var adjustments: [PhoneAdjustment] {
        switch self {
        case .basic: [.temperature, .tint, .saturation, .vibrance, .mixRed, .mixGreen, .mixBlue]
        case .selectiveColor:
            ColorRange.allCases.flatMap { [.selectiveHue($0), .selectiveSaturation($0), .selectiveBrightness($0)] }
        case .detail, .effects: groups(in: EditRecipe(), range: .red).flatMap(\.sliders)
        }
    }

    /// The segment's controls in groups, top to bottom, each under its heading and set apart
    /// from the next by a line. With Black & White on, the red, green and blue mix takes the
    /// place of Saturation and Vibrance. Selective Color shows the chosen range. A fine-tuning
    /// slider is in its amount's group, under the amount.
    public func groups(in recipe: EditRecipe, range: ColorRange) -> [PhoneSheetGroup] {
        switch self {
        case .basic:
            [PhoneSheetGroup(controls: [.blackAndWhite]),
             PhoneSheetGroup("Profile", controls: [.profile]),
             PhoneSheetGroup("White Balance", controls: [.whiteBalance], sliders: [.temperature, .tint]),
             recipe.blackAndWhite.isOn
                 ? PhoneSheetGroup("Black & White Mix", sliders: [.mixRed, .mixGreen, .mixBlue])
                 : PhoneSheetGroup("Color", sliders: [.saturation, .vibrance])]
        case .selectiveColor:
            [PhoneSheetGroup(controls: [.colorRanges]),
             PhoneSheetGroup(range.title, sliders: [.selectiveHue(range), .selectiveSaturation(range), .selectiveBrightness(range)])]
        case .detail:
            [PhoneSheetGroup("Presence", sliders: [.texture, .clarity, .dehaze]),
             PhoneSheetGroup("Sharpening", sliders: [.sharpness]),
             PhoneSheetGroup("Noise Reduction", sliders: [.noiseReduction, .noiseReductionDetail, .colorNoiseReduction]),
             // Two switches, as in Lightroom on iPhone. The manual distortion and lens vignetting
             // sliders stay on the Mac; the vignette is in Effects.
             PhoneSheetGroup("Lens Corrections", controls: [.lensSwitches])]
        case .effects:
            [PhoneSheetGroup("Grain", sliders: [.grain, .grainSize, .grainRoughness]),
             PhoneSheetGroup("Halation", sliders: [.halation, .halationSize]),
             PhoneSheetGroup("Bloom", sliders: [.bloom, .bloomSize]),
             PhoneSheetGroup("Vignette", sliders: [.vignette, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather])]
        }
    }

    /// The sliders shown, in order.
    public func sliders(in recipe: EditRecipe, range: ColorRange) -> [PhoneAdjustment] {
        groups(in: recipe, range: range).flatMap(\.sliders)
    }

    /// Resets each of the segment's sliders, leaving the rest of the recipe as it was. The Black
    /// & White switch, the profile and the lens switches stay, as no Mac card's Reset of a
    /// slider changes them.
    public func reset(in recipe: inout EditRecipe) {
        for adjustment in adjustments { adjustment.reset(in: &recipe) }
    }

    public func isChanged(in recipe: EditRecipe) -> Bool {
        adjustments.contains { $0.isChanged(in: recipe) }
    }
}

/// A control in an iPhone tool sheet other than a slider.
public enum PhoneSheetControl: Hashable, Sendable {
    /// The Black & White switch.
    case blackAndWhite
    /// The camera profile menu.
    case profile
    /// The white balance preset menu, with the eyedropper.
    case whiteBalance
    /// Selective Color's row of color ranges.
    case colorRanges
    /// The lens profile and chromatic aberration switches.
    case lensSwitches
}

/// A group of controls in a tool sheet's segment: a heading, then its other controls and its
/// sliders. Groups show what belongs together through the heading and a line between them,
/// so every slider keeps the sheet's full width.
public struct PhoneSheetGroup: Hashable, Sendable {
    public var title: String?
    public var controls: [PhoneSheetControl]
    public var sliders: [PhoneAdjustment]

    public init(_ title: String? = nil, controls: [PhoneSheetControl] = [], sliders: [PhoneAdjustment] = []) {
        self.title = title
        self.controls = controls
        self.sliders = sliders
    }
}

/// One slider in an iPhone tool sheet: the recipe value it reads and writes. Each writes only its
/// own value, so everything else in the recipe is left as it was.
public enum PhoneAdjustment: Hashable, CaseIterable, Identifiable, Sendable {
    case exposure, contrast, highlights, shadows, whites, blacks
    case temperature, tint, saturation, vibrance
    /// The black-and-white mix's channels.
    case mixRed, mixGreen, mixBlue
    case selectiveHue(ColorRange), selectiveSaturation(ColorRange), selectiveBrightness(ColorRange)
    case texture, clarity, dehaze
    case sharpness, noiseReduction, noiseReductionDetail, colorNoiseReduction
    case grain, grainSize, grainRoughness, halation, halationSize, bloom, bloomSize
    case vignette, vignetteMidpoint, vignetteRoundness, vignetteFeather

    public static let allCases: [PhoneAdjustment] =
        PhoneTool.light.adjustments + PhoneToolSection.allCases.flatMap(\.adjustments)

    public var id: Self { self }

    public var title: String {
        switch self {
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .whites: "Whites"
        case .blacks: "Blacks"
        case .temperature: "Temperature"
        case .tint: "Tint"
        case .saturation: "Saturation"
        case .vibrance: "Vibrance"
        case .mixRed: "Red"
        case .mixGreen: "Green"
        case .mixBlue: "Blue"
        case .selectiveHue: "Hue"
        case .selectiveSaturation: "Saturation"
        case .selectiveBrightness: "Brightness"
        case .texture: "Texture"
        case .clarity: "Clarity"
        case .dehaze: "Dehaze"
        // Titles within their group's heading, as on the Mac: "Amount" under Grain.
        case .sharpness, .grain, .halation, .bloom, .vignette: "Amount"
        case .noiseReduction: "Luminance"
        case .noiseReductionDetail: "Detail"
        case .colorNoiseReduction: "Color"
        case .vignetteMidpoint: "Midpoint"
        case .grainSize, .halationSize, .bloomSize: "Size"
        case .grainRoughness: "Roughness"
        case .vignetteRoundness: "Roundness"
        case .vignetteFeather: "Feather"
        }
    }

    /// What VoiceOver reads, where the title alone is shared with another slider.
    public var spokenTitle: String {
        switch self {
        case let .selectiveHue(range), let .selectiveSaturation(range), let .selectiveBrightness(range):
            "\(range.title) \(title)"
        case .mixRed, .mixGreen, .mixBlue: "Black & White \(title)"
        case .sharpness: "Sharpening Amount"
        case .grain: "Grain Amount"
        case .halation: "Halation Amount"
        case .bloom: "Bloom Amount"
        case .vignette: "Vignette Amount"
        case .noiseReduction: "Luminance Noise Reduction"
        case .noiseReductionDetail: "Noise Reduction Detail"
        case .colorNoiseReduction: "Color Noise Reduction"
        case .grainSize: "Grain Size"
        case .grainRoughness: "Grain Roughness"
        case .halationSize: "Halation Size"
        case .bloomSize: "Bloom Size"
        case .vignetteMidpoint: "Vignette Midpoint"
        case .vignetteRoundness: "Vignette Roundness"
        case .vignetteFeather: "Vignette Feather"
        default: title
        }
    }

    /// The amount a fine-tuning slider refines, which it follows in its group: what it changes
    /// is that amount's look. `nil` for an amount or a slider of its own.
    public var refines: PhoneAdjustment? {
        switch self {
        case .noiseReductionDetail, .colorNoiseReduction: .noiseReduction
        case .grainSize, .grainRoughness: .grain
        case .halationSize: .halation
        case .bloomSize: .bloom
        case .vignetteMidpoint, .vignetteRoundness, .vignetteFeather: .vignette
        default: nil
        }
    }

    /// The inspector card the value belongs to. A slider moved while its card is switched off
    /// switches the card on first, so the change shows.
    public var group: AdjustmentGroup {
        switch self {
        case .temperature, .tint: .whiteBalance
        case .selectiveHue, .selectiveSaturation, .selectiveBrightness: .selectiveColor
        case .sharpness, .noiseReduction, .noiseReductionDetail, .colorNoiseReduction: .detail
        case .grain, .grainSize, .grainRoughness, .halation, .halationSize, .bloom, .bloomSize,
             .vignette, .vignetteMidpoint, .vignetteRoundness, .vignetteFeather: .effects
        default: .basic
        }
    }

    public var range: ClosedRange<Double> {
        switch self {
        case .exposure: -5...5
        case .temperature: WhiteBalance.temperatureRange
        case .tint: WhiteBalance.tintRange
        case .mixRed, .mixGreen, .mixBlue: BlackAndWhite.range
        case .selectiveHue, .selectiveSaturation, .selectiveBrightness: ColorRangeAdjustment.range
        case .sharpness, .noiseReduction, .noiseReductionDetail, .colorNoiseReduction: DetailAdjustments.range
        case .grain: GrainAdjustments.amountRange
        case .grainSize: GrainAdjustments.sizeRange
        case .grainRoughness: GrainAdjustments.roughnessRange
        case .halation, .bloom: GlowAdjustments.amountRange
        case .halationSize, .bloomSize: GlowAdjustments.sizeRange
        case .vignette: VignetteAdjustments.amountRange
        case .vignetteMidpoint: VignetteAdjustments.midpointRange
        case .vignetteRoundness: VignetteAdjustments.roundnessRange
        case .vignetteFeather: VignetteAdjustments.featherRange
        default: -100...100
        }
    }

    /// Whether the slider is dimmed because it changes nothing as the recipe stands: in black
    /// and white only a range's Brightness changes the gray, and a fine-tuning slider does
    /// nothing without its amount, as on the Mac. Color noise reduction works on its own.
    public func isInactive(in recipe: EditRecipe, camera: CameraDetail?) -> Bool {
        switch self {
        case .selectiveHue, .selectiveSaturation: recipe.blackAndWhite.isOn
        case .colorNoiseReduction: false
        default: refines.map { ($0.value(in: recipe, asShot: nil, camera: camera) ?? 0) == 0 } ?? false
        }
    }

    /// The value the slider shows. Temperature and tint show the camera's white balance until they
    /// are changed, and sharpening and noise reduction the camera's amounts; `nil` until those
    /// have been read.
    public func value(in recipe: EditRecipe, asShot: WhiteBalance?, camera: CameraDetail?) -> Double? {
        switch self {
        case .exposure: recipe.basic.exposure
        case .contrast: recipe.basic.contrast
        case .highlights: recipe.basic.highlights
        case .shadows: recipe.basic.shadows
        case .whites: recipe.basic.whites
        case .blacks: recipe.basic.blacks
        case .temperature: asShot.map { recipe.basic.whiteBalance(asShot: $0).temperature }
        case .tint: asShot.map { recipe.basic.whiteBalance(asShot: $0).tint }
        case .saturation: recipe.basic.saturation
        case .vibrance: recipe.basic.vibrance
        case .mixRed: recipe.blackAndWhite.red
        case .mixGreen: recipe.blackAndWhite.green
        case .mixBlue: recipe.blackAndWhite.blue
        case let .selectiveHue(range): recipe.selectiveColor[range].hue
        case let .selectiveSaturation(range): recipe.selectiveColor[range].saturation
        case let .selectiveBrightness(range): recipe.selectiveColor[range].brightness
        case .texture: recipe.basic.texture
        case .clarity: recipe.basic.clarity
        case .dehaze: recipe.basic.dehaze
        case .sharpness: camera.map { recipe.detail.shown(camera: $0).sharpening ?? 0 }
        case .noiseReduction: camera.map { recipe.detail.shown(camera: $0).noiseReduction ?? 0 }
        case .noiseReductionDetail: camera.map { recipe.detail.shown(camera: $0).noiseReductionDetail ?? 0 }
        case .colorNoiseReduction: camera.map { recipe.detail.shown(camera: $0).colorNoiseReduction ?? 0 }
        case .grain: recipe.grain.amount
        case .grainSize: recipe.grain.size
        case .grainRoughness: recipe.grain.roughness
        case .halation: recipe.halation.amount
        case .halationSize: recipe.halation.size
        case .bloom: recipe.bloom.amount
        case .bloomSize: recipe.bloom.size
        case .vignette: recipe.vignette.amount
        case .vignetteMidpoint: recipe.vignette.midpoint
        case .vignetteRoundness: recipe.vignette.roundness
        case .vignetteFeather: recipe.vignette.feather
        }
    }

    public func set(_ value: Double, in recipe: inout EditRecipe) {
        switch self {
        case .exposure: recipe.basic.exposure = value
        case .contrast: recipe.basic.contrast = value
        case .highlights: recipe.basic.highlights = value
        case .shadows: recipe.basic.shadows = value
        case .whites: recipe.basic.whites = value
        case .blacks: recipe.basic.blacks = value
        case .temperature: recipe.basic.setTemperature(value)
        case .tint: recipe.basic.setTint(value)
        case .saturation: recipe.basic.saturation = value
        case .vibrance: recipe.basic.vibrance = value
        case .mixRed: recipe.blackAndWhite.red = value
        case .mixGreen: recipe.blackAndWhite.green = value
        case .mixBlue: recipe.blackAndWhite.blue = value
        case let .selectiveHue(range): recipe.selectiveColor[range].hue = value
        case let .selectiveSaturation(range): recipe.selectiveColor[range].saturation = value
        case let .selectiveBrightness(range): recipe.selectiveColor[range].brightness = value
        case .texture: recipe.basic.texture = value
        case .clarity: recipe.basic.clarity = value
        case .dehaze: recipe.basic.dehaze = value
        case .sharpness: recipe.detail.sharpening = value
        case .noiseReduction: recipe.detail.noiseReduction = value
        case .noiseReductionDetail: recipe.detail.noiseReductionDetail = value
        case .colorNoiseReduction: recipe.detail.colorNoiseReduction = value
        case .grain: recipe.grain.amount = value
        case .grainSize: recipe.grain.size = value
        case .grainRoughness: recipe.grain.roughness = value
        case .halation: recipe.halation.amount = value
        case .halationSize: recipe.halation.size = value
        case .bloom: recipe.bloom.amount = value
        case .bloomSize: recipe.bloom.size = value
        case .vignette: recipe.vignette.amount = value
        case .vignetteMidpoint: recipe.vignette.midpoint = value
        case .vignetteRoundness: recipe.vignette.roundness = value
        case .vignetteFeather: recipe.vignette.feather = value
        }
    }

    /// Back to the default: the camera's white balance, sharpening and noise reduction, or a new
    /// recipe's value.
    public func reset(in recipe: inout EditRecipe) {
        switch self {
        case .temperature: recipe.basic.resetTemperature()
        case .tint: recipe.basic.resetTint()
        case .sharpness: recipe.detail.sharpening = nil
        case .noiseReduction: recipe.detail.noiseReduction = nil
        case .noiseReductionDetail: recipe.detail.noiseReductionDetail = nil
        case .colorNoiseReduction: recipe.detail.colorNoiseReduction = nil
        default:
            if let value = value(in: EditRecipe(), asShot: nil, camera: nil) { set(value, in: &recipe) }
        }
    }

    /// Whether the value differs from what `reset(in:)` returns to.
    public func isChanged(in recipe: EditRecipe) -> Bool {
        var reset = recipe
        self.reset(in: &reset)
        return reset != recipe
    }
}

extension PhoneTool {
    /// Resets each of the tool's sliders, leaving the rest of the recipe as it was.
    public func reset(in recipe: inout EditRecipe) {
        for adjustment in adjustments { adjustment.reset(in: &recipe) }
    }

    public func isChanged(in recipe: EditRecipe) -> Bool {
        adjustments.contains { $0.isChanged(in: recipe) }
    }
}

/// White balance in the iPhone Color sheet (#298): the preset menu above Temperature and Tint,
/// and the eyedropper mode that sets them from a spot on the photo.
public enum PhoneWhiteBalance {
    /// The presets the menu lists, in the Mac's order. Custom isn't chosen, so it is listed only
    /// while it is what the sliders show, as on the Mac.
    public static func menu(showing current: WhiteBalancePreset) -> [WhiteBalancePreset] {
        WhiteBalancePreset.allCases.filter { $0 != .custom || current == .custom }
    }
}

/// The iPhone's eyedropper mode, from opening to Done or Cancel. Each spot sampled sets
/// Temperature and Tint, which the menu shows as Custom, and Cancel returns to the white
/// balance from when the mode opened. Only the white balance is written, so the rest of the
/// recipe is left as it is.
public struct WhiteBalanceSampling: Equatable, Sendable {
    private let preset: WhiteBalancePreset
    private let temperature: Double?
    private let tint: Double?
    private let wasSwitchedOff: Bool

    public init(from recipe: EditRecipe) {
        preset = recipe.basic.whiteBalance
        temperature = recipe.basic.temperature
        tint = recipe.basic.tint
        wasSwitchedOff = recipe.switchedOff.contains(.whiteBalance)
    }

    /// Sets the white balance the eyedropper found, switching the card on so it shows.
    public func sample(_ found: WhiteBalance, into recipe: inout EditRecipe) {
        recipe.switchedOff.remove(.whiteBalance)
        recipe.basic.setTemperature(found.temperature)
        recipe.basic.setTint(found.tint)
    }

    /// Cancel: the white balance, its preset and its card's switch as they were.
    public func restore(in recipe: inout EditRecipe) {
        recipe.basic.whiteBalance = preset
        recipe.basic.temperature = temperature
        recipe.basic.tint = tint
        if wasSwitchedOff { recipe.switchedOff.insert(.whiteBalance) } else { recipe.switchedOff.remove(.whiteBalance) }
    }
}
