import Foundation
import Testing
@testable import ProofKit

struct EditRecipeTests {
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

    @Test("A white balance preset this version doesn't know reads as Custom with its values")
    func unknownPresetIsCustom() throws {
        let json = #"{"formatVersion": 2, "basic": {"whiteBalance": "candlelight", "temperature": 1900, "tint": 5}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.basic.whiteBalance == .custom)
        #expect(recipe.basic.temperature == 1900)
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
