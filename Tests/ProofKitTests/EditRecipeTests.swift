import Foundation
import Testing
@testable import ProofKit

struct EditRecipeTests {
    @Test("The original keeps the crop and drops every adjustment")
    func originalKeepsCrop() {
        var recipe = EditRecipe()
        recipe.basic.exposure = 1
        recipe.vignette.amount = -20
        recipe.look = Look(lut: "Film.cube", strength: 0.5)
        recipe.crop = Crop(x: 0.1, y: 0.05, width: 0.8, height: 0.9, angle: 1.5)

        let original = recipe.original
        #expect(original.crop == recipe.crop)
        #expect(original.basic.isNeutral)
        #expect(original.vignette.isNeutral)
        #expect(original.look == nil)
        #expect(EditRecipe().original == EditRecipe())
    }

    @Test("A new recipe is neutral and has no layers")
    func newRecipeIsNeutral() {
        let recipe = EditRecipe()
        #expect(recipe.basic.isNeutral)
        #expect(recipe.curve == ToneCurve())
        #expect(recipe.look == nil)
        #expect(recipe.layers.isEmpty)
        #expect(recipe.formatVersion == EditRecipe.currentFormatVersion)
    }

    @Test("A recipe survives a JSON round trip")
    func roundTrip() throws {
        var recipe = EditRecipe()
        recipe.basic.exposure = 0.3
        recipe.basic.highlights = -40
        recipe.curve.rgb = [CurvePoint(0, 0.02), CurvePoint(0.5, 0.55), CurvePoint(1, 1)]
        recipe.look = Look(lut: "Portra.cube", strength: 0.7)
        recipe.crop = Crop(x: 0.1, y: 0.05, width: 0.8, height: 0.9, angle: 1.5)

        let data = try JSONEncoder().encode(recipe)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded == recipe)
    }

    @Test("Missing fields fall back to no adjustment")
    func missingFieldsDefault() throws {
        let json = #"{"formatVersion": 1, "basic": {"exposure": 1.5}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.basic.exposure == 1.5)
        #expect(recipe.basic.contrast == 0)
        #expect(recipe.curve == ToneCurve())
        #expect(recipe.layers.isEmpty)
    }

    @Test("A format 2 crop reads with no turn, flips or ratio, and saves as format 3")
    func migratesFormat2Crop() throws {
        let json = #"{"formatVersion": 2, "crop": {"x": 0.1, "y": 0.2, "width": 0.5, "height": 0.6, "angle": 2}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.crop == Crop(x: 0.1, y: 0.2, width: 0.5, height: 0.6, angle: 2))
        #expect(recipe.crop?.rotation == 0 && recipe.crop?.flipHorizontal == false && recipe.crop?.aspect == nil)
        #expect(recipe.formatVersion == 3)
    }

    @Test("A crop that changes nothing leaves the recipe neutral")
    func identityCropIsNeutral() {
        var recipe = EditRecipe()
        recipe.crop = Crop(aspect: AspectRatio(3, 2))
        #expect(recipe.isNeutral)
        recipe.crop?.rotation = 90
        #expect(!recipe.isNeutral)
    }

    @Test("A format 3 curve saved before levels reads with every handle at its default")
    func migratesCurveWithoutLevels() throws {
        let json = #"{"formatVersion": 3, "curve": {"rgb": [[0, 0], [0.5, 0.6], [1, 1]]}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.curve.rgb == [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)])
        #expect(recipe.curve.levels == ChannelLevels())
        let partial = #"{"curve": {"levels": {"red": [0.1, 0.4, 0.9]}}}"#
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: Data(partial.utf8))
        #expect(decoded.curve.levels.red == Levels(black: 0.1, midtone: 0.4, white: 0.9))
        #expect(decoded.curve.levels.rgb == Levels())
    }

    @Test("Levels encode as three-element arrays and survive a round trip")
    func levelsEncoding() throws {
        let data = try JSONEncoder().encode(Levels(black: 0.05, midtone: 0.5, white: 0.9))
        #expect(String(decoding: data, as: UTF8.self) == "[0.05,0.5,0.9]")
        var recipe = EditRecipe()
        recipe.curve.levels.blue = Levels(black: 0.1, midtone: 0.6, white: 1)
        #expect(!recipe.isNeutral)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded == recipe)
    }

    @Test("Curve points encode as two-element arrays")
    func curvePointEncoding() throws {
        let data = try JSONEncoder().encode(CurvePoint(0.25, 0.5))
        #expect(String(decoding: data, as: UTF8.self) == "[0.25,0.5]")
    }

    @Test("The sidecar sits next to the original with .proof appended")
    func sidecarURL() {
        let original = URL(fileURLWithPath: "/Volumes/home/Albums/2025/L1000957.DNG")
        #expect(EditRecipe.sidecarURL(for: original).path == "/Volumes/home/Albums/2025/L1000957.DNG.proof")
    }

    @Test("A recipe with any adjustment isn't neutral")
    func neutrality() {
        var recipe = EditRecipe()
        recipe.basic.shadows = 10
        #expect(!recipe.isNeutral)
        recipe.basic.shadows = 0
        recipe.look = Look(lut: "Portra.cube")
        #expect(!recipe.isNeutral)
        recipe.look = nil
        #expect(recipe.isNeutral)
    }

    @Test("No look and no crop are written as null")
    func absentValuesEncodeAsNull() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditRecipe())) as? [String: Any]
        #expect(object?["look"] is NSNull)
        #expect(object?["crop"] is NSNull)
    }

    @Test("As Shot white balance is written as null temperature and tint")
    func asShotEncodesAsNull() throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditRecipe())) as? [String: Any]
        let basic = object?["basic"] as? [String: Any]
        #expect(basic?["whiteBalance"] as? String == "asShot")
        #expect(basic?["temperature"] is NSNull)
        #expect(basic?["tint"] is NSNull)
    }

    @Test("A format 1 file's temperature and tint offsets are dropped, keeping the camera's white balance")
    func migratesFormat1WhiteBalance() throws {
        let json = #"""
        {"formatVersion": 1, "processVersion": 1, "basic": {"temperature": 12, "tint": -4, "exposure": 0.5},
         "layers": [{"name": "Sky", "isEnabled": true, "basic": {"temperature": 30, "tint": 0}}]}
        """#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.formatVersion == EditRecipe.currentFormatVersion)
        #expect(recipe.basic.whiteBalance == .asShot)
        #expect(recipe.basic.temperature == nil)
        #expect(recipe.basic.tint == nil)
        #expect(recipe.basic.exposure == 0.5)
        #expect(recipe.layers[0].basic.temperature == nil)
    }

    @Test("A format 2 white balance survives a JSON round trip")
    func whiteBalanceRoundTrip() throws {
        var recipe = EditRecipe()
        recipe.basic.choose(.tungsten)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded.basic.whiteBalance == .tungsten)
        #expect(decoded.basic.temperature == 2850)
        #expect(decoded.basic.tint == 0)
    }

    @Test("Auto white balance is written as auto with its values and survives a JSON round trip")
    func autoWhiteBalanceRoundTrip() throws {
        var recipe = EditRecipe()
        recipe.basic.setAuto(WhiteBalance(temperature: 7010, tint: -1))
        let data = try JSONEncoder().encode(recipe)
        let basic = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])["basic"] as? [String: Any]
        #expect(basic?["whiteBalance"] as? String == "auto")
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: data)
        #expect(decoded.basic.whiteBalance == .auto)
        #expect(decoded.basic.whiteBalance(asShot: Self.asShot) == WhiteBalance(temperature: 7010, tint: -1))
    }

    @Test("Choosing Auto from the menu changes nothing until the photo is measured, and Auto stays within range")
    func autoNeedsThePhoto() {
        var basic = BasicAdjustments()
        basic.choose(.auto)
        #expect(basic == BasicAdjustments())
        basic.setAuto(WhiteBalance(temperature: 90000, tint: -400))
        #expect(basic.temperature == WhiteBalance.temperatureRange.upperBound)
        #expect(basic.tint == WhiteBalance.tintRange.lowerBound)
    }

    @Test("A white balance preset this version doesn't know reads as Custom with its values")
    func unknownPresetIsCustom() throws {
        let json = #"{"formatVersion": 2, "basic": {"whiteBalance": "candlelight", "temperature": 1900, "tint": 5}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.basic.whiteBalance == .custom)
        #expect(recipe.basic.temperature == 1900)
    }

    @Test("A format 2 file's contrast, whites and blacks read and write unchanged, as the current format")
    func contrastWhitesBlacksRoundTrip() throws {
        let json = #"{"formatVersion": 2, "processVersion": 1, "basic": {"contrast": 35, "whites": -20, "blacks": 15.5}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.basic.contrast == 35)
        #expect(recipe.basic.whites == -20)
        #expect(recipe.basic.blacks == 15.5)
        #expect(recipe.processVersion == 1)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        let basic = try #require(written?["basic"] as? [String: Any])
        #expect(basic["contrast"] as? Double == 35)
        #expect(basic["whites"] as? Double == -20)
        #expect(basic["blacks"] as? Double == 15.5)
        #expect(written?["formatVersion"] as? Int == EditRecipe.currentFormatVersion)
    }

    @Test("A file saved before Texture and Clarity reads both as 0 and stays neutral; both survive a round trip")
    func migratesWithoutTextureClarity() throws {
        let old = #"{"formatVersion": 3, "processVersion": 1, "basic": {"contrast": 0, "highlights": 0}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        #expect(recipe.basic.texture == 0)
        #expect(recipe.basic.clarity == 0)
        #expect(recipe.isNeutral)
        #expect(recipe.processVersion == 1)

        var edited = recipe
        edited.basic.texture = 35
        edited.basic.clarity = -20.5
        #expect(!edited.isNeutral)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]
        let basic = try #require(written?["basic"] as? [String: Any])
        #expect(basic["texture"] as? Double == 35)
        #expect(basic["clarity"] as? Double == -20.5)
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(edited)) == edited)
    }

    @Test("A file saved before Dehaze reads it as 0 and stays neutral; it survives a round trip")
    func migratesWithoutDehaze() throws {
        let old = #"{"formatVersion": 3, "processVersion": 1, "basic": {"texture": 0, "clarity": 0}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        #expect(recipe.basic.dehaze == 0)
        #expect(recipe.isNeutral)
        #expect(recipe.processVersion == 1)

        var edited = recipe
        edited.basic.dehaze = -42.5
        #expect(!edited.isNeutral)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]
        let basic = try #require(written?["basic"] as? [String: Any])
        #expect(basic["dehaze"] as? Double == -42.5)
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(edited)) == edited)
    }

    @Test("A file saved before Vignette reads it as off and stays neutral; a partial one keeps its other defaults")
    func migratesWithoutVignette() throws {
        let old = #"{"formatVersion": 3, "processVersion": 1, "basic": {"dehaze": 0}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        #expect(recipe.vignette == VignetteAdjustments(amount: 0, midpoint: 50, roundness: 0, feather: 50))
        #expect(recipe.isNeutral)
        #expect(recipe.processVersion == 1)

        let partial = #"{"formatVersion": 3, "vignette": {"amount": -30}}"#
        let read = try JSONDecoder().decode(EditRecipe.self, from: Data(partial.utf8))
        #expect(read.vignette == VignetteAdjustments(amount: -30))

        var edited = recipe
        edited.vignette = VignetteAdjustments(amount: -42.5, midpoint: 30, roundness: -20, feather: 80)
        #expect(!edited.isNeutral)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]
        let vignette = try #require(written?["vignette"] as? [String: Any])
        #expect(vignette["amount"] as? Double == -42.5 && vignette["feather"] as? Double == 80)
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(edited)) == edited)
    }

    @Test("A file saved before Selective Color reads every range as unadjusted; a partial one keeps the rest at 0")
    func migratesWithoutSelectiveColor() throws {
        let old = #"{"formatVersion": 3, "processVersion": 1, "basic": {"saturation": 0}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        #expect(recipe.selectiveColor.isNeutral)
        #expect(ColorRange.allCases.allSatisfy { recipe.selectiveColor[$0] == ColorRangeAdjustment() })
        #expect(recipe.isNeutral)
        #expect(recipe.processVersion == 1)

        let partial = #"{"formatVersion": 3, "selectiveColor": {"green": {"saturation": -40}, "teal": {"hue": 10}}}"#
        let read = try JSONDecoder().decode(EditRecipe.self, from: Data(partial.utf8))
        #expect(read.selectiveColor[.green] == ColorRangeAdjustment(saturation: -40))
        #expect(read.selectiveColor[.red].isNeutral)

        var edited = recipe
        edited.selectiveColor[.orange] = ColorRangeAdjustment(hue: 12.5, saturation: -20, brightness: 30)
        #expect(!edited.isNeutral)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]
        let ranges = try #require(written?["selectiveColor"] as? [String: [String: Double]])
        #expect(Set(ranges.keys) == Set(ColorRange.allCases.map(\.rawValue)))
        #expect(ranges["orange"] == ["hue": 12.5, "saturation": -20, "brightness": 30])
        #expect(ranges["red"] == ["hue": 0, "saturation": 0, "brightness": 0])
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(edited)) == edited)

        edited.selectiveColor[.orange] = ColorRangeAdjustment()
        #expect(edited.isNeutral)
    }

    @Test("A file saved before Black & White reads as Color with an even mix; a partial one keeps the rest at 0")
    func migratesWithoutBlackAndWhite() throws {
        let old = #"{"formatVersion": 3, "processVersion": 1, "basic": {"saturation": 0}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        #expect(recipe.blackAndWhite == BlackAndWhite())
        #expect(recipe.isNeutral)
        #expect(recipe.processVersion == 1)

        let partial = #"{"formatVersion": 3, "blackAndWhite": {"isOn": true, "blue": -30}}"#
        let read = try JSONDecoder().decode(EditRecipe.self, from: Data(partial.utf8))
        #expect(read.blackAndWhite == BlackAndWhite(isOn: true, blue: -30))

        var edited = recipe
        edited.blackAndWhite = BlackAndWhite(isOn: true, red: 25, green: -10.5, blue: 0)
        #expect(!edited.isNeutral)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]
        let mix = try #require(written?["blackAndWhite"] as? [String: Any])
        #expect(mix["isOn"] as? Bool == true)
        #expect(mix["red"] as? Double == 25 && mix["green"] as? Double == -10.5 && mix["blue"] as? Double == 0)
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(edited)) == edited)

        // Back to Color keeps the mix, which then doesn't render.
        edited.blackAndWhite.isOn = false
        #expect(edited.isNeutral)
        #expect(edited.original.blackAndWhite == BlackAndWhite())
    }

    static let asShot = WhiteBalance(temperature: 6112, tint: 10)

    @Test("A preset sets its Kelvin with no tint, and As Shot clears both")
    func choosingPresets() {
        var basic = BasicAdjustments()
        basic.choose(.shade)
        #expect(basic.whiteBalance(asShot: Self.asShot) == WhiteBalance(temperature: 7500, tint: 0))
        #expect(!basic.isNeutral)
        basic.choose(.asShot)
        #expect(basic.isNeutral)
    }

    @Test("Moving the temperature makes the white balance Custom and leaves the camera's tint")
    func settingTemperature() {
        var basic = BasicAdjustments()
        basic.setTemperature(4700)
        #expect(basic.whiteBalance == .custom)
        #expect(basic.whiteBalance(asShot: Self.asShot) == WhiteBalance(temperature: 4700, tint: 10))
        basic.setTint(-200)
        #expect(basic.tint == -150)
        basic.setTemperature(90000)
        #expect(basic.temperature == 50000)
    }

    @Test("Resetting temperature and tint one by one returns to As Shot")
    func resettingOneByOne() {
        var basic = BasicAdjustments()
        basic.choose(.daylight)
        basic.resetTemperature()
        #expect(basic.whiteBalance == .custom)
        #expect(basic.whiteBalance(asShot: Self.asShot) == WhiteBalance(temperature: 6112, tint: 0))
        basic.resetTint()
        #expect(basic.whiteBalance == .asShot)
        #expect(basic.isNeutral)
    }

    @Test("The temperature slider is spaced in mireds, so the ends and the middle land where expected")
    func temperatureSliderSpacing() {
        #expect(WhiteBalance.sliderPosition(forTemperature: 2000) == 0)
        #expect(WhiteBalance.sliderPosition(forTemperature: 50000) == 1)
        #expect(WhiteBalance.sliderPosition(forTemperature: 10000) > 0.8)
        for kelvin in [2000.0, 2850, 5500, 6112, 12000, 50000] {
            let position = WhiteBalance.sliderPosition(forTemperature: kelvin)
            #expect(abs(WhiteBalance.temperature(atSliderPosition: position) - kelvin) < 0.001)
        }
    }
}
