import Testing
@testable import ProofKit

struct PhoneToolTests {
    @Test("The toolbar has Looks, Light, Color, Finish and Crop, in that order")
    func toolOrder() {
        #expect(PhoneTool.allCases.map(\.title) == ["Looks", "Light", "Color", "Finish", "Crop"])
        #expect(PhoneTool.allCases.filter(\.hasSheet) == [.looks, .light, .color, .finish])
    }

    @Test("Each tool sheet shows the sliders the issue lists, and Finish has no fade")
    func sheetSliders() {
        #expect(PhoneTool.looks.adjustments.isEmpty)
        #expect(PhoneTool.light.adjustments == [.exposure, .contrast, .highlights, .shadows, .whites, .blacks])
        #expect(PhoneTool.color.adjustments == [.temperature, .tint, .saturation, .vibrance])
        #expect(PhoneTool.finish.adjustments == [.grain, .clarity, .sharpness, .vignette])
        #expect(PhoneTool.crop.adjustments.isEmpty)
        // Every slider belongs to exactly one tool.
        let all = PhoneTool.allCases.flatMap(\.adjustments)
        #expect(all.count == PhoneAdjustment.allCases.count)
        #expect(Set(all) == Set(PhoneAdjustment.allCases))
    }

    /// A recipe with something in every part iPhone has no control for.
    private var macEdit: EditRecipe {
        var recipe = EditRecipe()
        recipe.basic.texture = 20
        recipe.basic.dehaze = 15
        recipe.curve.rgb = [CurvePoint(0, 0.1), CurvePoint(1, 0.9)]
        recipe.blackAndWhite.isOn = true
        recipe.detail.noiseReduction = 40
        recipe.look = Look(lut: "Film/Warm.cube", strength: 0.6)
        recipe.vignette.midpoint = 30
        recipe.grain.size = 70
        recipe.halation.amount = 25
        recipe.bloom.amount = 10
        recipe.lens.distortion = 10
        recipe.transform.vertical = 12
        recipe.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8, angle: 2)
        recipe.switchedOff = [.curve]
        return recipe
    }

    @Test("Moving and resetting every iPhone slider leaves what iPhone has no control for untouched")
    func hiddenAdjustmentsSurvive() {
        let original = macEdit
        var recipe = original
        for adjustment in PhoneAdjustment.allCases {
            adjustment.set(adjustment.range.upperBound, in: &recipe)
        }
        for tool in PhoneTool.allCases { tool.reset(in: &recipe) }
        #expect(recipe.curve == original.curve)
        #expect(recipe.blackAndWhite == original.blackAndWhite)
        #expect(recipe.detail.noiseReduction == 40)
        #expect(recipe.look == original.look)
        #expect(recipe.vignette.midpoint == 30)
        #expect(recipe.grain.size == 70)
        #expect(recipe.halation == original.halation)
        #expect(recipe.bloom == original.bloom)
        #expect(recipe.lens == original.lens)
        #expect(recipe.transform == original.transform)
        #expect(recipe.crop == original.crop)
        #expect(recipe.spots == original.spots)
        #expect(recipe.layers == original.layers)
        #expect(recipe.switchedOff == original.switchedOff)
        #expect(recipe.basic.texture == 20)
        #expect(recipe.basic.dehaze == 15)
    }

    @Test("Each slider writes only its own value")
    func slidersWriteOneValue() {
        for adjustment in PhoneAdjustment.allCases {
            var recipe = macEdit
            let value = adjustment.range.lowerBound + (adjustment.range.upperBound - adjustment.range.lowerBound) * 0.75
            adjustment.set(value, in: &recipe)
            #expect(adjustment.value(in: recipe, asShot: WhiteBalance(temperature: 5500, tint: 0), camera: Self.camera) == value)
            for other in PhoneAdjustment.allCases where other != adjustment {
                #expect(other.value(in: recipe, asShot: WhiteBalance(temperature: 5500, tint: 0), camera: Self.camera)
                        == other.value(in: macEdit, asShot: WhiteBalance(temperature: 5500, tint: 0), camera: Self.camera),
                        "\(adjustment) changed \(other)")
            }
        }
    }

    private static let camera = CameraDetail(sharpness: 0.5, luminanceNoiseReduction: 0.2, detail: 0.5, colorNoiseReduction: 0.3)

    @Test("White balance and sharpness show the camera's until changed, and reset back to it")
    func cameraDefaults() {
        var recipe = EditRecipe()
        let asShot = WhiteBalance(temperature: 6100, tint: 8)
        #expect(PhoneAdjustment.temperature.value(in: recipe, asShot: asShot, camera: nil) == 6100)
        #expect(PhoneAdjustment.tint.value(in: recipe, asShot: asShot, camera: nil) == 8)
        #expect(PhoneAdjustment.temperature.value(in: recipe, asShot: nil, camera: nil) == nil)
        #expect(PhoneAdjustment.sharpness.value(in: recipe, asShot: nil, camera: Self.camera) == 25)
        #expect(PhoneAdjustment.sharpness.value(in: recipe, asShot: nil, camera: nil) == nil)

        PhoneAdjustment.temperature.set(4000, in: &recipe)
        PhoneAdjustment.sharpness.set(60, in: &recipe)
        #expect(recipe.basic.whiteBalance == .custom)
        #expect(PhoneTool.color.isChanged(in: recipe))
        PhoneTool.color.reset(in: &recipe)
        PhoneTool.finish.reset(in: &recipe)
        #expect(recipe.basic.whiteBalance == .asShot)
        #expect(recipe.detail.sharpening == nil)
        #expect(recipe == EditRecipe())
        #expect(!PhoneTool.color.isChanged(in: recipe))
    }

    @Test("Sliders move the cards they belong to, so a switched-off card is switched on")
    func groups() {
        #expect(PhoneTool.light.adjustments.allSatisfy { $0.group == .basic })
        #expect(PhoneAdjustment.temperature.group == .whiteBalance)
        #expect(PhoneAdjustment.saturation.group == .basic)
        #expect(PhoneAdjustment.sharpness.group == .detail)
        #expect(PhoneAdjustment.grain.group == .effects)
        #expect(PhoneAdjustment.vignette.group == .effects)
        #expect(PhoneAdjustment.clarity.group == .basic)
    }
}
