import CoreGraphics
import Testing
@testable import ProofKit

struct CopiedSettingsTests {
    static var source: EditRecipe {
        var recipe = AdjustmentGroupTests.edited
        recipe.basic.highlights = -50
        recipe.blackAndWhite = BlackAndWhite(isOn: true, red: 20)
        recipe.lens.distortion = 12
        recipe.grain = GrainAdjustments(amount: 30)
        recipe.transform.upright = .level
        recipe.transform.guides = [GuideLine(start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.1, y: 0.9))]
        recipe.crop = Crop(width: 0.5, height: 0.5, angle: 3)
        return recipe
    }

    static var target: EditRecipe {
        var recipe = EditRecipe()
        recipe.basic.exposure = -1
        recipe.basic.clarity = 10
        recipe.crop = Crop(x: 0.2, width: 0.8, rotation: 1)
        return recipe
    }

    @Test("Pasting every item makes the edit match the copied one, Transform's guides and the crop included")
    func pastesEverything() {
        let pasted = Self.target.pasting(CopiedSettings(from: Self.source, items: Set(SettingsItem.allCases)))
        #expect(pasted == Self.source)
    }

    @Test("Pasting the default items leaves the target's crop and Transform as they were")
    func defaultsKeepGeometry() {
        let pasted = Self.target.pasting(CopiedSettings(from: Self.source, items: SettingsItem.defaultItems))
        #expect(pasted.crop == Self.target.crop)
        #expect(pasted.transform == Self.target.transform)
        #expect(pasted.basic == Self.source.basic)
    }

    @Test("Items that aren't copied keep the target photo's values")
    func keepsUncopiedItems() {
        let pasted = Self.target.pasting(CopiedSettings(from: Self.source, items: [.exposure, .highlights, .look]))
        #expect(pasted.basic.exposure == Self.source.basic.exposure)
        #expect(pasted.basic.highlights == -50)
        #expect(pasted.basic.contrast == 0)
        #expect(pasted.look == Self.source.look)
        #expect(pasted.basic.clarity == 10)
        #expect(pasted.basic.temperature == nil)
        #expect(pasted.curve == ToneCurve())
        #expect(!pasted.blackAndWhite.isOn)
        #expect(pasted.crop == Self.target.crop)
    }

    @Test("A neutral copied item resets that item on the target")
    func pastesNeutralValues() {
        let pasted = Self.target.pasting(CopiedSettings(from: EditRecipe(), items: [.exposure, .clarity]))
        #expect(pasted.basic.exposure == 0)
        #expect(pasted.basic.clarity == 0)
        #expect(pasted.crop == Self.target.crop)
    }

    @Test("Noise Reduction copies its Detail slider with it, and leaves sharpening alone")
    func pastesNoiseReduction() {
        var source = EditRecipe()
        source.detail.sharpening = 80
        source.detail.noiseReduction = 40
        source.detail.noiseReductionDetail = 60
        let pasted = EditRecipe().pasting(CopiedSettings(from: source, items: [.noiseReduction]))
        #expect(pasted.detail.noiseReduction == 40)
        #expect(pasted.detail.noiseReductionDetail == 60)
        #expect(pasted.detail.sharpening == nil)
    }

    @Test("Every card has at least one item, and every item but Crop belongs to one card")
    func groupsCoverEveryItem() {
        let grouped = AdjustmentGroup.allCases.flatMap { SettingsItem.items(in: $0) }
        #expect(AdjustmentGroup.allCases.allSatisfy { !SettingsItem.items(in: $0).isEmpty })
        #expect(grouped.count == SettingsItem.allCases.count - 1)
        #expect(Set(grouped) == Set(SettingsItem.allCases).subtracting([.crop]))
    }

    @Test("Transform and Crop start unticked; every other item starts ticked")
    func defaultItems() {
        #expect(SettingsItem.defaultItems == Set(SettingsItem.allCases).subtracting([.transform, .crop]))
    }
}
