import Testing
@testable import ProofKit

struct AdjustmentGroupTests {
    static var edited: EditRecipe {
        var recipe = EditRecipe()
        recipe.basic.setTemperature(4000)
        recipe.basic.exposure = 1
        recipe.basic.contrast = 20
        recipe.basic.blacks = -10
        recipe.basic.vibrance = 30
        recipe.basic.saturation = -15
        recipe.curve.rgb = [CurvePoint(0, 0.1), CurvePoint(1, 1)]
        recipe.detail.sharpening = 70
        recipe.look = Look(lut: "Portra/400.cube", strength: 0.6)
        return recipe
    }

    @Test("Curve, Detail and Looks start off, unless the recipe has a curve, changed detail or a look")
    func initiallyOff() {
        #expect(AdjustmentGroup.initiallyOff(for: nil) == [.curve, .detail, .look])
        #expect(AdjustmentGroup.initiallyOff(for: EditRecipe()) == [.curve, .detail, .look])
        #expect(AdjustmentGroup.initiallyOff(for: Self.edited).isEmpty)
        var lookOnly = EditRecipe()
        lookOnly.look = Look(lut: "Mono.cube")
        #expect(AdjustmentGroup.initiallyOff(for: lookOnly) == [.curve, .detail])
    }

    @Test("A group switched off renders as if its adjustments were neutral, and leaves the others")
    func withoutGroups() {
        let recipe = Self.edited
        #expect(recipe.without([]) == recipe)
        #expect(recipe.without(Set(AdjustmentGroup.allCases)).isNeutral)

        let noLight = recipe.without([.light])
        #expect(noLight.basic.exposure == 0 && noLight.basic.contrast == 0 && noLight.basic.blacks == 0)
        #expect(noLight.basic.whiteBalance == recipe.basic.whiteBalance)
        #expect(noLight.basic.vibrance == 30 && noLight.curve == recipe.curve && noLight.look == recipe.look)

        let noWhiteBalance = recipe.without([.whiteBalance])
        #expect(noWhiteBalance.basic.whiteBalance == .asShot)
        #expect(noWhiteBalance.basic.exposure == 1)

        let noColorCurveLook = recipe.without([.color, .curve, .look])
        #expect(noColorCurveLook.basic.vibrance == 0 && noColorCurveLook.basic.saturation == 0)
        #expect(noColorCurveLook.curve == ToneCurve() && noColorCurveLook.look == nil)
        #expect(noColorCurveLook.basic.exposure == 1 && noColorCurveLook.detail == recipe.detail)

        let noDetail = recipe.without([.detail])
        #expect(noDetail.detail == DetailAdjustments() && noDetail.curve == recipe.curve)
    }
}
