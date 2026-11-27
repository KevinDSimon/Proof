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
