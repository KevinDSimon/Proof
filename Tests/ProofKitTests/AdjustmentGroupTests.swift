import Testing
@testable import ProofKit

struct AdjustmentGroupTests {
    static var edited: EditRecipe {
        var recipe = EditRecipe()
        recipe.basic.setTemperature(4000)
        recipe.basic.exposure = 1
        recipe.basic.contrast = 20
        recipe.basic.texture = 25
        recipe.basic.clarity = -30
        recipe.basic.dehaze = 40
        recipe.basic.blacks = -10
        recipe.basic.vibrance = 30
        recipe.basic.saturation = -15
        recipe.selectiveColor[.blue] = ColorRangeAdjustment(saturation: -30)
        recipe.curve.rgb = [CurvePoint(0, 0.1), CurvePoint(1, 1)]
        recipe.detail.sharpening = 70
        recipe.look = Look(lut: "Portra/400.cube", strength: 0.6)
        recipe.vignette = VignetteAdjustments(amount: -40, feather: 70)
        recipe.transform = PerspectiveTransform(vertical: -20)
        return recipe
    }

    @Test("Selective Color, Curve, Detail, Transform, Effects and Looks start off, unless the recipe has that adjustment")
    func initiallyOff() {
        #expect(AdjustmentGroup.initiallyOff(for: nil) == [.selectiveColor, .curve, .detail, .transform, .effects, .look])
        #expect(AdjustmentGroup.initiallyOff(for: EditRecipe()) == [.selectiveColor, .curve, .detail, .transform, .effects, .look])
        #expect(AdjustmentGroup.initiallyOff(for: Self.edited).isEmpty)
        var lookOnly = EditRecipe()
        lookOnly.look = Look(lut: "Mono.cube")
        #expect(AdjustmentGroup.initiallyOff(for: lookOnly) == [.selectiveColor, .curve, .detail, .transform, .effects])
        var vignetteOnly = EditRecipe()
        vignetteOnly.vignette.amount = 25
        #expect(AdjustmentGroup.initiallyOff(for: vignetteOnly) == [.selectiveColor, .curve, .detail, .transform, .look])
        var selectiveOnly = EditRecipe()
        selectiveOnly.selectiveColor[.green] = ColorRangeAdjustment(hue: 20)
        #expect(AdjustmentGroup.initiallyOff(for: selectiveOnly) == [.curve, .detail, .transform, .effects, .look])
        #expect(selectiveOnly.without([.selectiveColor]).selectiveColor.isNeutral)
        var grayOnly = EditRecipe()
        grayOnly.blackAndWhite = BlackAndWhite(isOn: true, red: 40)
        #expect(AdjustmentGroup.initiallyOff(for: grayOnly) == [.selectiveColor, .curve, .detail, .transform, .effects, .look])
        #expect(grayOnly.without([.basic]).blackAndWhite == BlackAndWhite(isOn: false, red: 40))
        #expect(grayOnly.without([.basic]).isNeutral)
    }

    @Test("Lens Corrections switched off renders without any lens correction, the profile included, and leaves the rest")
    func withoutLens() {
        var recipe = Self.edited
        recipe.lens = LensCorrections(chromaticAberration: ChromaticAberration(red: 1.001, blue: 0.999),
                                      distortion: 20, vignetting: LensVignetting(amount: 40))
        let noLens = recipe.without([.lens])
        #expect(noLens.lens == LensCorrections(profile: false))
        #expect(!noLens.lens.appliesProfile(for: CameraLens(hasProfile: true, profileIsOnByDefault: true)))
        #expect(noLens.basic == recipe.basic && noLens.vignette == recipe.vignette && noLens.crop == recipe.crop)
        #expect(recipe.without([.effects]).lens == recipe.lens)
        // Lens Corrections starts on, so a photo whose profile applies by default opens as before.
        #expect(!AdjustmentGroup.initiallyOff(for: EditRecipe()).contains(.lens))
    }

    @Test("A group switched off renders as if its adjustments were neutral, and leaves the others")
    func withoutGroups() {
        let recipe = Self.edited
        #expect(recipe.without([]) == recipe)
        var none = recipe.without(Set(AdjustmentGroup.allCases))
        #expect(none.lens == LensCorrections(profile: false))
        none.lens = LensCorrections()
        #expect(none.isNeutral)

        #expect(recipe.without([.transform]).transform.isNeutral && recipe.without([.lens]).transform == recipe.transform)

        let noBasic = recipe.without([.basic])
        #expect(noBasic.basic.exposure == 0 && noBasic.basic.contrast == 0 && noBasic.basic.blacks == 0)
        #expect(noBasic.basic.texture == 0 && noBasic.basic.clarity == 0 && noBasic.basic.dehaze == 0)
        #expect(noBasic.basic.vibrance == 0 && noBasic.basic.saturation == 0)
        #expect(noBasic.basic.whiteBalance == recipe.basic.whiteBalance)
        #expect(noBasic.curve == recipe.curve && noBasic.look == recipe.look)

        let noWhiteBalance = recipe.without([.whiteBalance])
        #expect(noWhiteBalance.basic.whiteBalance == .asShot)
        #expect(noWhiteBalance.basic.exposure == 1)

        let noCurveLook = recipe.without([.curve, .look])
        #expect(noCurveLook.curve == ToneCurve() && noCurveLook.look == nil)
        #expect(noCurveLook.vignette == recipe.vignette)
        #expect(recipe.without([.effects]).vignette.isNeutral && recipe.without([.effects]).look == recipe.look)
        #expect(noCurveLook.basic.exposure == 1 && noCurveLook.basic.vibrance == 30 && noCurveLook.detail == recipe.detail)

        let noDetail = recipe.without([.detail])
        #expect(noDetail.detail == DetailAdjustments() && noDetail.curve == recipe.curve)
    }
}
