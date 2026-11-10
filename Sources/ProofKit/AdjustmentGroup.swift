/// A group of adjustments that the inspector shows on one card with its own switch.
public enum AdjustmentGroup: Hashable, Sendable, CaseIterable {
    case whiteBalance, light, color, curve, look

    /// The groups whose switches start off when `recipe` opens: Curve and Looks, so their larger
    /// controls stay closed, unless the recipe has a curve or a look.
    public static func initiallyOff(for recipe: EditRecipe?) -> Set<AdjustmentGroup> {
        var off: Set<AdjustmentGroup> = []
        if recipe?.curve.isIdentity ?? true { off.insert(.curve) }
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
        if groups.contains(.look) { recipe.look = nil }
        return recipe
    }
}
