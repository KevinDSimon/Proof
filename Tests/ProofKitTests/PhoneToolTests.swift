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
        #expect(PhoneTool.color.adjustments == PhoneToolSection.basic.adjustments + PhoneToolSection.selectiveColor.adjustments)
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
        #expect(PhoneAdjustment.mixRed.group == .basic)
        #expect(PhoneAdjustment.selectiveBrightness(.aqua).group == .selectiveColor)
    }

    @Test("Color has Basic and Selective Color segments and opens at the medium height")
    func colorSegments() {
        #expect(PhoneTool.color.sections == [.basic, .selectiveColor])
        #expect(PhoneTool.color.sections.map(\.title) == ["Basic", "Selective Color"])
        #expect(PhoneTool.color.opensAtMediumHeight)
        #expect(!PhoneTool.light.opensAtMediumHeight)
        #expect(!PhoneTool.looks.opensAtMediumHeight)
        #expect(PhoneTool.light.sections.isEmpty)
    }

    @Test("Color's segments are groups under headings: Black & White, Profile, White Balance, then Color or the mix")
    func colorGroups() {
        var recipe = EditRecipe()
        let basic = PhoneToolSection.basic.groups(in: recipe, range: .red)
        #expect(basic.map(\.title) == [nil, "Profile", "White Balance", "Color"])
        #expect(basic.map(\.controls) == [[.blackAndWhite], [.profile], [.whiteBalance], []])
        recipe.blackAndWhite.isOn = true
        #expect(PhoneToolSection.basic.groups(in: recipe, range: .red).last?.title == "Black & White Mix")
        let selective = PhoneToolSection.selectiveColor.groups(in: recipe, range: .purple)
        #expect(selective.map(\.title) == [nil, "Purple"])
        #expect(selective.first?.controls == [.colorRanges])
    }

    @Test("With Black & White on, the mix takes the place of Saturation and Vibrance")
    func blackAndWhiteMix() {
        var recipe = EditRecipe()
        #expect(PhoneToolSection.basic.sliders(in: recipe, range: .red) == [.temperature, .tint, .saturation, .vibrance])
        recipe.blackAndWhite.isOn = true
        #expect(PhoneToolSection.basic.sliders(in: recipe, range: .red) == [.temperature, .tint, .mixRed, .mixGreen, .mixBlue])
        PhoneAdjustment.mixGreen.set(-40, in: &recipe)
        #expect(recipe.blackAndWhite.green == -40)
        #expect(recipe.blackAndWhite.red == 0 && recipe.blackAndWhite.blue == 0)
    }

    @Test("Selective Color shows the chosen range, and in black and white dims its Hue and Saturation")
    func selectiveColor() {
        var recipe = EditRecipe()
        #expect(PhoneToolSection.selectiveColor.sliders(in: recipe, range: .blue)
                == [.selectiveHue(.blue), .selectiveSaturation(.blue), .selectiveBrightness(.blue)])
        PhoneAdjustment.selectiveSaturation(.blue).set(30, in: &recipe)
        #expect(recipe.selectiveColor[.blue].saturation == 30)
        #expect(recipe.selectiveColor[.aqua].isNeutral)
        #expect(PhoneAdjustment.selectiveHue(.blue).spokenTitle == "Blue Hue")
        #expect(PhoneToolSection.selectiveColor.sliders(in: recipe, range: .blue).allSatisfy { !$0.isInactive(in: recipe) })
        recipe.blackAndWhite.isOn = true
        #expect(PhoneAdjustment.selectiveHue(.blue).isInactive(in: recipe))
        #expect(PhoneAdjustment.selectiveSaturation(.blue).isInactive(in: recipe))
        #expect(!PhoneAdjustment.selectiveBrightness(.blue).isInactive(in: recipe))
    }

    @Test("Reset in a segment resets only that segment, and keeps the Black & White switch and profile")
    func sectionReset() {
        var recipe = EditRecipe(profile: .apple)
        recipe.blackAndWhite.isOn = true
        PhoneAdjustment.mixRed.set(20, in: &recipe)
        PhoneAdjustment.temperature.set(4000, in: &recipe)
        PhoneAdjustment.selectiveBrightness(.orange).set(-25, in: &recipe)
        #expect(PhoneToolSection.basic.isChanged(in: recipe))
        #expect(PhoneToolSection.selectiveColor.isChanged(in: recipe))

        var basicReset = recipe
        PhoneToolSection.basic.reset(in: &basicReset)
        #expect(!PhoneToolSection.basic.isChanged(in: basicReset))
        #expect(basicReset.blackAndWhite.isOn)
        #expect(basicReset.blackAndWhite.red == 0)
        #expect(basicReset.basic.whiteBalance == .asShot)
        #expect(basicReset.profile == .apple)
        #expect(basicReset.selectiveColor == recipe.selectiveColor)

        var selectiveReset = recipe
        PhoneToolSection.selectiveColor.reset(in: &selectiveReset)
        #expect(selectiveReset.selectiveColor.isNeutral)
        #expect(selectiveReset.blackAndWhite == recipe.blackAndWhite)
        #expect(selectiveReset.basic == recipe.basic)
    }

    @Test("The white balance menu lists Custom only once a slider has moved")
    func whiteBalanceMenu() {
        let presets: [WhiteBalancePreset] = [.asShot, .auto, .daylight, .cloudy, .shade, .tungsten, .fluorescent, .flash]
        #expect(PhoneWhiteBalance.menu(showing: .asShot) == presets)
        var recipe = EditRecipe()
        recipe.basic.choose(.tungsten)
        #expect(recipe.basic.whiteBalance == .tungsten)
        #expect(PhoneWhiteBalance.menu(showing: recipe.basic.whiteBalance) == presets)
        PhoneAdjustment.temperature.set(3000, in: &recipe)
        #expect(recipe.basic.whiteBalance == .custom)
        #expect(PhoneWhiteBalance.menu(showing: recipe.basic.whiteBalance) == presets + [.custom])
        // Choosing a preset again leaves Custom out of the menu.
        recipe.basic.choose(.daylight)
        #expect(PhoneWhiteBalance.menu(showing: recipe.basic.whiteBalance) == presets)
    }

    @Test("A sampled spot sets Temperature and Tint as Custom, and switches White Balance on")
    func sampleWhiteBalance() {
        var recipe = macEdit
        recipe.basic.choose(.cloudy)
        recipe.switchedOff.insert(.whiteBalance)
        let sampling = WhiteBalanceSampling(from: recipe)
        sampling.sample(WhiteBalance(temperature: 4200, tint: 12), into: &recipe)
        #expect(recipe.basic.whiteBalance == .custom)
        #expect(recipe.basic.temperature == 4200)
        #expect(recipe.basic.tint == 12)
        #expect(recipe.switchedOff == [.curve])
        // Out of range values are kept to the sliders' ranges.
        sampling.sample(WhiteBalance(temperature: 90000, tint: -400), into: &recipe)
        #expect(recipe.basic.temperature == WhiteBalance.temperatureRange.upperBound)
        #expect(recipe.basic.tint == WhiteBalance.tintRange.lowerBound)
    }

    @Test("Cancel returns to the white balance from when the eyedropper opened, leaving the rest")
    func cancelSampling() {
        var start = macEdit
        start.basic.choose(.shade)
        start.switchedOff.insert(.whiteBalance)
        var recipe = start
        let sampling = WhiteBalanceSampling(from: recipe)
        sampling.sample(WhiteBalance(temperature: 3900, tint: -8), into: &recipe)
        sampling.sample(WhiteBalance(temperature: 5100, tint: 4), into: &recipe)
        sampling.restore(in: &recipe)
        #expect(recipe == start)

        // As Shot comes back with the camera's values, not the last sample's.
        var asShot = macEdit
        let fromAsShot = WhiteBalanceSampling(from: asShot)
        fromAsShot.sample(WhiteBalance(temperature: 6100, tint: 20), into: &asShot)
        fromAsShot.restore(in: &asShot)
        #expect(asShot == macEdit)
        #expect(asShot.basic.whiteBalance == .asShot)
        #expect(asShot.basic.temperature == nil && asShot.basic.tint == nil)
    }
}
