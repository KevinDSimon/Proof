/// A group of adjustments that the inspector shows on one card with its own switch.
public enum AdjustmentGroup: Hashable, Sendable, CaseIterable {
    case whiteBalance, light, color, selectiveColor, curve, detail, lens, transform, vignette, look

    /// The groups whose switches start off when `recipe` opens: Selective Color, Curve, Detail,
    /// Transform, Vignette and Looks, so their controls stay closed, unless the recipe has a
    /// selective color adjustment, a curve, changed detail, a perspective correction, a vignette
    /// or a look. Detail is judged at 100% zoom, so most photos never need it open.
    public static func initiallyOff(for recipe: EditRecipe?) -> Set<AdjustmentGroup> {
        var off: Set<AdjustmentGroup> = []
        if recipe?.selectiveColor.isNeutral ?? true { off.insert(.selectiveColor) }
        if recipe?.curve.isIdentity ?? true { off.insert(.curve) }
        if recipe?.detail.isNeutral ?? true { off.insert(.detail) }
        if recipe?.transform.isNeutral ?? true { off.insert(.transform) }
        if recipe?.vignette.isNeutral ?? true { off.insert(.vignette) }
        if recipe?.look == nil { off.insert(.look) }
        return off
    }
}

extension EditRecipe {
    /// The recipe with the adjustments of `groups` left out, as the canvas shows it while their
    /// switches are off.
    public func without(_ groups: Set<AdjustmentGroup>) -> EditRecipe {
        var recipe = self
        if groups.contains(.whiteBalance) { recipe.basic.resetWhiteBalance() }
        if groups.contains(.light) {
            recipe.basic.exposure = 0
            recipe.basic.contrast = 0
            recipe.basic.texture = 0
            recipe.basic.clarity = 0
            recipe.basic.dehaze = 0
            recipe.basic.highlights = 0
            recipe.basic.shadows = 0
            recipe.basic.whites = 0
            recipe.basic.blacks = 0
        }
        if groups.contains(.color) {
            recipe.basic.vibrance = 0
            recipe.basic.saturation = 0
        }
        if groups.contains(.selectiveColor) { recipe.selectiveColor = SelectiveColor() }
        if groups.contains(.curve) { recipe.curve = ToneCurve() }
        if groups.contains(.detail) { recipe.detail = DetailAdjustments() }
        // Off means no lens correction at all, the profile included, even where the decoder
        // applies it by default, so the switch shows the lens as it drew the photo.
        if groups.contains(.lens) { recipe.lens = LensCorrections(profile: false) }
        if groups.contains(.transform) { recipe.transform = PerspectiveTransform() }
        if groups.contains(.vignette) { recipe.vignette = VignetteAdjustments() }
        if groups.contains(.look) { recipe.look = nil }
        return recipe
    }
}
