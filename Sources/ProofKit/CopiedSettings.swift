/// One checkbox in the Copy Settings sheet, as in Lightroom's: a slider, a section of a card,
/// or a card with one control. The sheet groups them by card, with Profile, Crop, Spot Removal and Masks on their own.
public enum SettingsItem: String, CaseIterable, Codable, Hashable, Sendable {
    case profile
    case whiteBalance
    case exposure, contrast, highlights, shadows, whites, blacks,
         texture, clarity, dehaze, treatment, vibrance, saturation
    case toneCurve
    case selectiveColor
    case sharpening, noiseReduction, colorNoiseReduction
    case lensProfile, chromaticAberration, distortion, lensVignetting
    case transform
    case crop
    case spotRemoval
    case masks
    case vignette, grain, halation, bloom
    case look

    /// Ticked the first time the sheet opens: everything but Transform, Crop, Spot Removal and
    /// Masks, which fit the photo they came from. Transform and Crop suit others only when nothing
    /// moved, as on a tripod; spots suit others when they cover sensor dust, which stays put on the
    /// sensor; masks are drawn around what one photo shows.
    public static let defaultItems: Set<SettingsItem> = Set(allCases).subtracting([.transform, .crop, .spotRemoval, .masks])

    /// The inspector card that shows the item: the sheet groups items by it, and a paste sets
    /// its switch as the copied photo had it. `nil` for Profile, which has no switch, and for Crop, Spot Removal and
    /// Masks, which their tools show.
    public var group: AdjustmentGroup? {
        switch self {
        case .whiteBalance: .whiteBalance
        case .exposure, .contrast, .highlights, .shadows, .whites, .blacks,
             .texture, .clarity, .dehaze, .treatment, .vibrance, .saturation: .basic
        case .toneCurve: .curve
        case .selectiveColor: .selectiveColor
        case .sharpening, .noiseReduction, .colorNoiseReduction: .detail
        case .lensProfile, .chromaticAberration, .distortion, .lensVignetting: .lens
        case .transform: .transform
        case .profile, .crop, .spotRemoval, .masks: nil
        case .vignette, .grain, .halation, .bloom: .effects
        case .look: .look
        }
    }

    /// The items of `group`, in the order its card shows them.
    public static func items(in group: AdjustmentGroup) -> [SettingsItem] {
        allCases.filter { $0.group == group }
    }

    /// The Copy Settings sheet's groups in the inspector's order, below Profile. `nil` holds Crop,
    /// Spot Removal and Masks, tools rather than cards, beside Transform. The Mac lays them out in
    /// columns and iOS in one list.
    public static let sheetGroups: [AdjustmentGroup?] = [
        .look, .whiteBalance, .basic, .curve, .selectiveColor, .detail, .lens, .transform, nil, .effects,
    ]

    /// The items of one of the sheet's groups: a card's, or the tools' for `nil`.
    public static func items(inSheetGroup group: AdjustmentGroup?) -> [SettingsItem] {
        group.map(items(in:)) ?? [.crop, .spotRemoval, .masks]
    }
}

/// Adjustments copied from one photo, to paste onto others.
public struct CopiedSettings: Equatable, Sendable {
    public var recipe: EditRecipe
    public var items: Set<SettingsItem>

    public init(from recipe: EditRecipe, items: Set<SettingsItem>) {
        self.recipe = recipe
        self.items = items
    }
}

extension EditRecipe {
    /// The recipe with the copied items replaced by their values in `copied`. The switch of each
    /// card with a copied item comes along, so the pasted settings render as they did on the
    /// copied photo. Everything else stays as it was.
    public func pasting(_ copied: CopiedSettings) -> EditRecipe {
        var recipe = self
        let source = copied.recipe
        for group in Set(copied.items.compactMap(\.group)) {
            if source.switchedOff.contains(group) { recipe.switchedOff.insert(group) } else { recipe.switchedOff.remove(group) }
        }
        for item in copied.items {
            switch item {
            // Ticked by default: white balance values mean different colors under each profile.
            // A photo without the choice ignores it.
            case .profile: recipe.profile = source.profile
            case .whiteBalance:
                recipe.basic.whiteBalance = source.basic.whiteBalance
                recipe.basic.temperature = source.basic.temperature
                recipe.basic.tint = source.basic.tint
            case .exposure: recipe.basic.exposure = source.basic.exposure
            case .contrast: recipe.basic.contrast = source.basic.contrast
            case .highlights: recipe.basic.highlights = source.basic.highlights
            case .shadows: recipe.basic.shadows = source.basic.shadows
            case .whites: recipe.basic.whites = source.basic.whites
            case .blacks: recipe.basic.blacks = source.basic.blacks
            case .texture: recipe.basic.texture = source.basic.texture
            case .clarity: recipe.basic.clarity = source.basic.clarity
            case .dehaze: recipe.basic.dehaze = source.basic.dehaze
            case .treatment: recipe.blackAndWhite = source.blackAndWhite
            case .vibrance: recipe.basic.vibrance = source.basic.vibrance
            case .saturation: recipe.basic.saturation = source.basic.saturation
            case .toneCurve: recipe.curve = source.curve
            case .selectiveColor: recipe.selectiveColor = source.selectiveColor
            case .sharpening: recipe.detail.sharpening = source.detail.sharpening
            case .noiseReduction:
                recipe.detail.noiseReduction = source.detail.noiseReduction
                recipe.detail.noiseReductionDetail = source.detail.noiseReductionDetail
            case .colorNoiseReduction: recipe.detail.colorNoiseReduction = source.detail.colorNoiseReduction
            case .lensProfile: recipe.lens.profile = source.lens.profile
            case .chromaticAberration: recipe.lens.chromaticAberration = source.lens.chromaticAberration
            case .distortion: recipe.lens.distortion = source.lens.distortion
            case .lensVignetting: recipe.lens.vignetting = source.lens.vignetting
            case .transform: recipe.transform = source.transform
            // The rectangle lies in the photo as turned and flipped, so the turns, flips,
            // straighten angle and ratio come with it.
            case .crop: recipe.crop = source.crop
            // Every spot, replacing the target's, so pasting onto a photo twice doesn't double them.
            case .spotRemoval: recipe.spots = source.spots
            // Every layer, replacing the target's, as spots are.
            case .masks: recipe.layers = source.layers
            case .vignette: recipe.vignette = source.vignette
            case .grain: recipe.grain = source.grain
            case .halation: recipe.halation = source.halation
            case .bloom: recipe.bloom = source.bloom
            case .look: recipe.look = source.look
            }
        }
        return recipe
    }
}
