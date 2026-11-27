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
        default: []
        }
    }

    /// Every slider the tool's sheet can show, in order. A tool with segments shows them one
    /// segment at a time. Looks shows the LUT library instead, and Crop has no sheet.
    public var adjustments: [PhoneAdjustment] {
        switch self {
        case .looks, .crop: []
        case .light: [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]
        case .color: sections.flatMap(\.adjustments)
        case .finish: [.grain, .clarity, .sharpness, .vignette]
        }
    }

    /// Whether the tool opens a sheet.
    public var hasSheet: Bool { self != .crop }

    /// Whether the sheet opens at the medium height rather than the compact one: the segments and
    /// rows above the sliders leave no room for one at the compact height.
    public var opensAtMediumHeight: Bool { !sections.isEmpty }
}

/// One segment of an iPhone tool sheet, named for the Mac's card it comes from.
public enum PhoneToolSection: String, CaseIterable, Identifiable, Sendable {
    case basic, selectiveColor

    public var id: Self { self }

    public var title: String {
        switch self {
        case .basic: "Basic"
        case .selectiveColor: "Selective Color"
        }
    }

    /// Every slider the segment can show, for Reset.
    public var adjustments: [PhoneAdjustment] {
        switch self {
        case .basic: [.temperature, .tint, .saturation, .vibrance, .mixRed, .mixGreen, .mixBlue]
        case .selectiveColor:
            ColorRange.allCases.flatMap { [.selectiveHue($0), .selectiveSaturation($0), .selectiveBrightness($0)] }
        }
    }

    /// The sliders shown, in order. With Black & White on, the red, green and blue mix takes the
    /// place of Saturation and Vibrance. Selective Color shows the chosen range.
    public func sliders(in recipe: EditRecipe, range: ColorRange) -> [PhoneAdjustment] {
        switch self {
        case .basic:
            [.temperature, .tint] + (recipe.blackAndWhite.isOn ? [.mixRed, .mixGreen, .mixBlue] : [.saturation, .vibrance])
        case .selectiveColor: [.selectiveHue(range), .selectiveSaturation(range), .selectiveBrightness(range)]
        }
    }

    /// Resets each of the segment's sliders, leaving the rest of the recipe as it was. The Black
    /// & White switch and the profile stay, as no Mac card's Reset changes them.
    public func reset(in recipe: inout EditRecipe) {
        for adjustment in adjustments { adjustment.reset(in: &recipe) }
    }

    public func isChanged(in recipe: EditRecipe) -> Bool {
        adjustments.contains { $0.isChanged(in: recipe) }
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
    case grain, clarity, sharpness, vignette

    public static let allCases: [PhoneAdjustment] =
        [.exposure, .contrast, .highlights, .shadows, .whites, .blacks,
         .temperature, .tint, .saturation, .vibrance, .mixRed, .mixGreen, .mixBlue]
        + PhoneToolSection.selectiveColor.adjustments
        + [.grain, .clarity, .sharpness, .vignette]

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
        case .grain: "Grain"
        case .clarity: "Clarity"
        case .sharpness: "Sharpness"
        case .vignette: "Vignette"
        }
    }

    /// What VoiceOver reads, where the title alone is shared with another slider.
    public var spokenTitle: String {
        switch self {
        case let .selectiveHue(range), let .selectiveSaturation(range), let .selectiveBrightness(range):
            "\(range.title) \(title)"
        case .mixRed, .mixGreen, .mixBlue: "Black & White \(title)"
        default: title
        }
    }

    /// The inspector card the value belongs to. A slider moved while its card is switched off
    /// switches the card on first, so the change shows.
    public var group: AdjustmentGroup {
        switch self {
        case .temperature, .tint: .whiteBalance
        case .selectiveHue, .selectiveSaturation, .selectiveBrightness: .selectiveColor
        case .sharpness: .detail
        case .grain, .vignette: .effects
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
        case .grain: GrainAdjustments.amountRange
        case .vignette: VignetteAdjustments.amountRange
        case .sharpness: DetailAdjustments.range
        default: -100...100
        }
    }

    /// Whether the slider is dimmed because it changes nothing as the recipe stands: in black
    /// and white only a range's Brightness changes the gray.
    public func isInactive(in recipe: EditRecipe) -> Bool {
        switch self {
        case .selectiveHue, .selectiveSaturation: recipe.blackAndWhite.isOn
        default: false
        }
    }

    /// The value the slider shows. Temperature and tint show the camera's white balance until they
    /// are changed, and sharpness the camera's amount; `nil` until those have been read.
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
        case .grain: recipe.grain.amount
        case .clarity: recipe.basic.clarity
        case .sharpness: camera.map { recipe.detail.shown(camera: $0).sharpening ?? 0 }
        case .vignette: recipe.vignette.amount
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
        case .grain: recipe.grain.amount = value
        case .clarity: recipe.basic.clarity = value
        case .sharpness: recipe.detail.sharpening = value
        case .vignette: recipe.vignette.amount = value
        }
    }
    /// Back to the default: zero, the camera's white balance or the camera's sharpening.
    public func reset(in recipe: inout EditRecipe) {
        switch self {
        case .temperature: recipe.basic.resetTemperature()
        case .tint: recipe.basic.resetTint()
        case .sharpness: recipe.detail.sharpening = nil
        case .grain: recipe.grain.amount = EditRecipe().grain.amount
        case .vignette: recipe.vignette.amount = EditRecipe().vignette.amount
        default: set(0, in: &recipe)
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
