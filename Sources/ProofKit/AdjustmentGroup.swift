/// A group of adjustments that the inspector shows on one card with its own switch. The raw
/// values are saved in `EditRecipe.switchedOff`.
public enum AdjustmentGroup: String, Hashable, Sendable, CaseIterable {
    case whiteBalance, basic, selectiveColor, curve, detail, lens, transform, effects, look

    /// The inspector card's title.
    public var title: String {
        switch self {
        case .whiteBalance: "White Balance"
        case .basic: "Basic"
        case .curve: "Curve"
        case .selectiveColor: "Selective Color"
        case .detail: "Detail"
        case .lens: "Lens Corrections"
        case .transform: "Transform"
        case .effects: "Effects"
        case .look: "Look"
        }
    }

    /// The groups whose switches start off when `recipe` opens, besides those it switched off:
    /// Selective Color, Curve, Detail, Transform, Effects and Looks, so their controls stay closed,
    /// unless the recipe has a selective color adjustment, a curve, changed detail, a perspective
    /// correction, an effect or a look. Detail is judged at 100% zoom, so most photos never need it
    /// open. These are at their defaults, so their switches change nothing that renders.
    public static func initiallyOff(for recipe: EditRecipe?) -> Set<AdjustmentGroup> {
        var off: Set<AdjustmentGroup> = []
        if recipe?.selectiveColor.isNeutral ?? true { off.insert(.selectiveColor) }
        if recipe?.curve.isIdentity ?? true { off.insert(.curve) }
        if recipe?.detail.isNeutral ?? true { off.insert(.detail) }
        if recipe?.transform.isNeutral ?? true { off.insert(.transform) }
        if recipe?.hasNoEffects ?? true { off.insert(.effects) }
        if recipe?.look == nil { off.insert(.look) }
        return off
    }
}

extension EditRecipe {
    /// The recipe as it renders: without the adjustments of the groups it switched off. The
    /// renderer applies this itself, so the canvas, thumbnails and export all leave them out.
    public var rendered: EditRecipe {
        switchedOff.isEmpty ? self : without(switchedOff)
    }

    /// Whether switching `group` off would change how the photo renders: false for a card at its
    /// defaults, whose switch is then only a way to close it and isn't saved.
    public func rendersDifferently(without group: AdjustmentGroup) -> Bool {
        without([group]) != self
    }

    /// The recipe with the adjustments of `groups` left out, as it renders while their switches
    /// are off. `switchedOff` is left as it is.
    public func without(_ groups: Set<AdjustmentGroup>) -> EditRecipe {
        var recipe = self
        if groups.contains(.whiteBalance) { recipe.basic.resetWhiteBalance() }
        if groups.contains(.basic) {
            recipe.basic.exposure = 0
            recipe.basic.contrast = 0
            recipe.basic.texture = 0
            recipe.basic.clarity = 0
            recipe.basic.dehaze = 0
            recipe.basic.highlights = 0
            recipe.basic.shadows = 0
            recipe.basic.whites = 0
            recipe.basic.blacks = 0
            recipe.basic.vibrance = 0
            recipe.basic.saturation = 0
            recipe.blackAndWhite.isOn = false
        }
        if groups.contains(.selectiveColor) { recipe.selectiveColor = SelectiveColor() }
        if groups.contains(.curve) { recipe.curve = ToneCurve() }
        if groups.contains(.detail) { recipe.detail = DetailAdjustments() }
        // Off means no lens correction at all, the profile included, even where the decoder
        // applies it by default, so the switch shows the lens as it drew the photo.
        if groups.contains(.lens) { recipe.lens = LensCorrections(profile: false) }
        if groups.contains(.transform) { recipe.transform = PerspectiveTransform() }
        if groups.contains(.effects) { recipe.removeEffects() }
        if groups.contains(.look) { recipe.look = nil }
        return recipe
    }
}

extension EditRecipe {
    /// Whether the Effects card is at its defaults: no vignette, grain, halation or bloom.
    public var hasNoEffects: Bool {
        vignette.isNeutral && grain.isNeutral && halation.isNeutral && bloom.isNeutral
    }

    /// Sets the Effects card back to its defaults.
    public mutating func removeEffects() {
        vignette = VignetteAdjustments()
        grain = GrainAdjustments()
        halation = GlowAdjustments()
        bloom = GlowAdjustments()
    }
}

/// The inspector cards folded with their disclosure arrows, by title. Folding is apart from a
/// card's switch: a card that is on can be folded out of the way and keep its adjustments, and it
/// stays folded from photo to photo (decision 0034). A card that is off is closed either way.
public struct FoldedCards: Hashable, Sendable {
    public private(set) var titles: Set<String>

    public init(_ titles: Set<String> = []) {
        self.titles = titles
    }

    /// Whether the card titled `title` shows its controls.
    public func isExpanded(_ title: String, isOn: Bool = true) -> Bool {
        isOn && !titles.contains(title)
    }

    public mutating func setFolded(_ title: String, _ isFolded: Bool) {
        if isFolded { titles.insert(title) } else { titles.remove(title) }
    }
}
