/// A group of adjustments that the inspector shows on one card with its own switch.
public enum AdjustmentGroup: Hashable, Sendable, CaseIterable {
    case whiteBalance, light, color, curve, detail, look

    /// The groups whose switches start off when `recipe` opens: Curve, Detail and Looks, so their
    /// controls stay closed, unless the recipe has a curve, changed detail or a look. Detail is
    /// judged at 100% zoom, so most photos never need it open.
    public static func initiallyOff(for recipe: EditRecipe?) -> Set<AdjustmentGroup> {
        var off: Set<AdjustmentGroup> = []
        if recipe?.curve.isIdentity ?? true { off.insert(.curve) }
        if recipe?.detail.isNeutral ?? true { off.insert(.detail) }
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
            recipe.basic.highlights = 0
            recipe.basic.shadows = 0
            recipe.basic.whites = 0
            recipe.basic.blacks = 0
        }
        if groups.contains(.color) {
            recipe.basic.vibrance = 0
            recipe.basic.saturation = 0
        }
        if groups.contains(.curve) { recipe.curve = ToneCurve() }
        if groups.contains(.detail) { recipe.detail = DetailAdjustments() }
        if groups.contains(.look) { recipe.look = nil }
        return recipe
    }
}
