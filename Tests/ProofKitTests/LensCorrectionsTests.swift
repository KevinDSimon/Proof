import CoreImage
import Foundation
import ImageIO
import Testing
@testable import ProofKit

struct LensCorrectionsTests {
    @Test("Without its own setting an edit follows the decoder's default, and a photo without a profile never gets one")
    func appliesProfile() {
        let onByDefault = CameraLens(hasProfile: true, profileIsOnByDefault: true)
        let offByDefault = CameraLens(hasProfile: true, profileIsOnByDefault: false)
        let none = CameraLens(name: "Summicron-M 1:2/35 ASPH.")

        #expect(LensCorrections().appliesProfile(for: onByDefault))
        #expect(!LensCorrections().appliesProfile(for: offByDefault))
        #expect(!LensCorrections(profile: false).appliesProfile(for: onByDefault))
        #expect(LensCorrections(profile: true).appliesProfile(for: offByDefault))
        #expect(!LensCorrections(profile: true).appliesProfile(for: none))
    }

    @Test("A file saved before Lens Corrections keeps the decoder's default and stays neutral; a setting survives a round trip")
    func migratesWithoutLens() throws {
        let old = #"{"formatVersion": 3, "processVersion": 1, "basic": {"dehaze": 0}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        #expect(recipe.lens == LensCorrections(profile: nil))
        #expect(recipe.isNeutral)
        #expect(recipe.processVersion == 1)

        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        let lens = try #require(written?["lens"] as? [String: Any])
        #expect(lens["profile"] is NSNull)

        var edited = recipe
        edited.lens.profile = false
        #expect(!edited.isNeutral)
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(edited)) == edited)
    }

    @Test("A lens setting saved before manual corrections has none; manual corrections survive a round trip and write null when off")
    func migratesWithoutManual() throws {
        let old = #"{"formatVersion": 3, "processVersion": 1, "lens": {"profile": null, "chromaticAberration": {"red": 1.001, "blue": 0.999}}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        #expect(recipe.lens.distortion == nil)
        #expect(recipe.lens.vignetting == nil)
        #expect(recipe.processVersion == 1)

        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any]
        let lens = try #require(written?["lens"] as? [String: Any])
        #expect(lens["distortion"] is NSNull)
        #expect(lens["vignetting"] is NSNull)

        var edited = EditRecipe()
        edited.lens.distortion = 12
        edited.lens.vignetting = LensVignetting(amount: 40, midpoint: 30)
        #expect(!edited.isNeutral)
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(edited)) == edited)
        #expect(LensCorrections(distortion: 0, vignetting: LensVignetting(amount: 0, midpoint: 20)).isNeutral)
    }

    @Test("Show Original keeps the lens corrections, so it frames the same picture")
    func originalKeepsLens() {
        var recipe = EditRecipe()
        recipe.basic.exposure = 1
        recipe.lens.profile = false
        #expect(recipe.original.lens == recipe.lens)
        #expect(recipe.original.basic.isNeutral)
    }

    @Test("The lens name comes from the EXIF lens model, then the auxiliary one; a blank name is none")
    func readsName() {
        let exif: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: " Summicron-M 1:2/50 "]]
        #expect(CameraLens.name(in: exif) == "Summicron-M 1:2/50")
        let aux: [CFString: Any] = [kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: ""],
                                    kCGImagePropertyExifAuxDictionary: [kCGImagePropertyExifAuxLensModel: "Super-Elmar-M 1:3.4/21 ASPH."]]
        #expect(CameraLens.name(in: aux) == "Super-Elmar-M 1:3.4/21 ASPH.")
        #expect(CameraLens.name(in: [:]) == nil)
    }

    /// RAW files can't be committed, so this runs only when `PROOF_SAMPLE_DNG` names one.
    @Test("A real RAW photo's lens is read, and a photo without a profile renders the same with it turned on",
          .enabled(if: sampleDNG != nil))
    func sampleLens() async throws {
        let url = try #require(sampleDNG)
        let lens = try #require(CameraLens.of(url))
        #expect(lens.name != nil)
        guard !lens.hasProfile else { return }

        let renderer = try RAWRenderer()
        func pixels(_ recipe: EditRecipe) async throws -> Data? {
            try await renderer.thumbnail(of: url, recipe: recipe, maxPixelSize: 300).dataProvider?.data as Data?
        }
        let plain = try await pixels(EditRecipe())
        #expect(plain != nil)
        #expect(try await pixels(EditRecipe(lens: LensCorrections(profile: true))) == plain)
    }
}
