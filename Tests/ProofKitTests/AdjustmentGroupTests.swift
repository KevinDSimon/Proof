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
        recipe.curve.rgb = [CurvePoint(0, 0.1), CurvePoint(1, 1)]
        recipe.detail.sharpening = 70
        recipe.look = Look(lut: "Portra/400.cube", strength: 0.6)
        recipe.vignette = VignetteAdjustments(amount: -40, feather: 70)
        recipe.transform = PerspectiveTransform(vertical: -20)
        return recipe
    }

    @Test("Curve, Detail, Transform, Vignette and Looks start off, unless the recipe has a curve, changed detail, a perspective correction, a vignette or a look")
    func initiallyOff() {
        #expect(AdjustmentGroup.initiallyOff(for: nil) == [.curve, .detail, .transform, .vignette, .look])
        #expect(AdjustmentGroup.initiallyOff(for: EditRecipe()) == [.curve, .detail, .transform, .vignette, .look])
        #expect(AdjustmentGroup.initiallyOff(for: Self.edited).isEmpty)
        var lookOnly = EditRecipe()
        lookOnly.look = Look(lut: "Mono.cube")
        #expect(AdjustmentGroup.initiallyOff(for: lookOnly) == [.curve, .detail, .transform, .vignette])
        var vignetteOnly = EditRecipe()
        vignetteOnly.vignette.amount = 25
        #expect(AdjustmentGroup.initiallyOff(for: vignetteOnly) == [.curve, .detail, .transform, .look])
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
        #expect(recipe.without([.vignette]).lens == recipe.lens)
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

        let noLight = recipe.without([.light])
        #expect(noLight.basic.exposure == 0 && noLight.basic.contrast == 0 && noLight.basic.blacks == 0)
        #expect(noLight.basic.texture == 0 && noLight.basic.clarity == 0 && noLight.basic.dehaze == 0)
        #expect(noLight.basic.whiteBalance == recipe.basic.whiteBalance)
        #expect(noLight.basic.vibrance == 30 && noLight.curve == recipe.curve && noLight.look == recipe.look)

        let noWhiteBalance = recipe.without([.whiteBalance])
        #expect(noWhiteBalance.basic.whiteBalance == .asShot)
        #expect(noWhiteBalance.basic.exposure == 1)

        let noColorCurveLook = recipe.without([.color, .curve, .look])
        #expect(noColorCurveLook.basic.vibrance == 0 && noColorCurveLook.basic.saturation == 0)
        #expect(noColorCurveLook.curve == ToneCurve() && noColorCurveLook.look == nil)
        #expect(noColorCurveLook.vignette == recipe.vignette)
        #expect(recipe.without([.vignette]).vignette.isNeutral && recipe.without([.vignette]).look == recipe.look)
        #expect(noColorCurveLook.basic.exposure == 1 && noColorCurveLook.detail == recipe.detail)

        let noDetail = recipe.without([.detail])
        #expect(noDetail.detail == DetailAdjustments() && noDetail.curve == recipe.curve)
    }
}
