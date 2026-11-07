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
}
