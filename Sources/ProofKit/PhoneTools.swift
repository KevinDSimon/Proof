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

    /// The sliders the tool's sheet shows, in order. Looks shows the LUT library instead, and
    /// Crop has no sheet.
    public var adjustments: [PhoneAdjustment] {
        switch self {
        case .looks, .crop: []
        case .light: [.exposure, .contrast, .highlights, .shadows, .whites, .blacks]
        case .color: [.temperature, .tint, .saturation, .vibrance]
        case .finish: [.grain, .clarity, .sharpness, .vignette]
        }
    }

    /// Whether the tool opens a sheet.
    public var hasSheet: Bool { self != .crop }
}

/// One slider in an iPhone tool sheet: the recipe value it reads and writes. Each writes only its
/// own value, so everything else in the recipe is left as it was.
public enum PhoneAdjustment: String, CaseIterable, Identifiable, Sendable {
    case exposure, contrast, highlights, shadows, whites, blacks
    case temperature, tint, saturation, vibrance
    case grain, clarity, sharpness, vignette

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
        case .grain: "Grain"
        case .clarity: "Clarity"
        case .sharpness: "Sharpness"
        case .vignette: "Vignette"
        }
    }

    /// The inspector card the value belongs to. A slider moved while its card is switched off
    /// switches the card on first, so the change shows.
    public var group: AdjustmentGroup {
        switch self {
        case .temperature, .tint: .whiteBalance
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
        case .grain: GrainAdjustments.amountRange
        case .vignette: VignetteAdjustments.amountRange
        case .sharpness: DetailAdjustments.range
        default: -100...100
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
