import Foundation
import Testing
@testable import ProofKit

struct SidecarTests {
    let photo: URL

    init() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        photo = folder.appendingPathComponent("L1000957.DNG")
        try Data("raw".utf8).write(to: photo)
    }

    var sidecarURL: URL { EditRecipe.sidecarURL(for: photo) }
    var sidecarExists: Bool { FileManager.default.fileExists(atPath: sidecarURL.path) }

    func edited(exposure: Double) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.basic.exposure = exposure
        return recipe
    }

    @Test("A photo without a sidecar reads as having none")
    func noSidecar() throws {
        #expect(try Sidecar.read(for: photo) == nil)
    }

    @Test("A saved edit is read back the same")
    func saveAndRead() throws {
        let saved = try Sidecar.save(edited(exposure: 0.3), for: photo, over: nil)
        #expect(sidecarExists)
        let read = try #require(try Sidecar.read(for: photo))
        #expect(read.recipe == edited(exposure: 0.3))
        #expect(read == saved)
    }

    @Test("Saving a neutral edit when there is no sidecar writes nothing")
    func neutralWritesNothing() throws {
        #expect(try Sidecar.save(EditRecipe(), for: photo, over: nil) == nil)
        #expect(!sidecarExists)
    }

    @Test("Returning every value to neutral deletes the sidecar")
    func neutralDeletes() throws {
        let saved = try Sidecar.save(edited(exposure: 1), for: photo, over: nil)
        #expect(try Sidecar.save(EditRecipe(), for: photo, over: saved) == nil)
        #expect(!sidecarExists)
    }

    @Test("Reverting deletes the sidecar, even one with unrecognized fields")
    func revertDeletes() throws {
        let json = #"{"formatVersion": 1, "basic": {"exposure": 1}, "lightLeak": {"amount": 30}}"#
        try Data(json.utf8).write(to: sidecarURL)
        try Sidecar.delete(for: photo)
        #expect(!sidecarExists)
    }

    @Test("Reverting a photo without a sidecar does nothing")
    func revertWithoutSidecar() throws {
        try Sidecar.delete(for: photo)
        #expect(!sidecarExists)
    }

    @Test("Undoing a revert writes the edit back as a new sidecar")
    func undoRevertWritesNewSidecar() throws {
        try Sidecar.save(edited(exposure: 0.5), for: photo, over: nil)
        try Sidecar.delete(for: photo)

        try Sidecar.save(edited(exposure: 0.5), for: photo, over: nil)
        #expect(try Sidecar.read(for: photo)?.recipe == edited(exposure: 0.5))
    }

    @Test("A sidecar with unrecognized fields is kept when the edit returns to neutral")
    func unrecognizedKeptWhenNeutral() throws {
        let json = #"{"formatVersion": 1, "basic": {"exposure": 1, "texture": 20}, "lightLeak": {"amount": 30}}"#
        try Data(json.utf8).write(to: sidecarURL)
        let read = try #require(try Sidecar.read(for: photo))
        #expect(read.hasUnrecognizedFields)

        let saved = try Sidecar.save(EditRecipe(), for: photo, over: read)
        #expect(sidecarExists)
        #expect(saved?.recipe == EditRecipe())
    }

    @Test("Saving keeps fields this version doesn't recognize, at any depth")
    func unrecognizedSurviveSave() throws {
        let json = #"""
        {"formatVersion": 1, "basic": {"exposure": 1, "texture": 20}, "lightLeak": {"amount": 30},
         "layers": [{"name": "Sky", "isEnabled": true, "basic": {"exposure": -1}, "mask": {"kind": "sky"}}]}
        """#
        try Data(json.utf8).write(to: sidecarURL)
        var recipe = try #require(try Sidecar.read(for: photo)).recipe
        recipe.basic.exposure = 0.5
        recipe.layers[0].basic.exposure = -0.5

        try Sidecar.save(recipe, for: photo, over: Sidecar.read(for: photo))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
        let basic = try #require(object["basic"] as? [String: Any])
        #expect(basic["exposure"] as? Double == 0.5)
        #expect(basic["texture"] as? Double == 20)
        #expect((object["lightLeak"] as? [String: Any])?["amount"] as? Double == 30)
        let layer = try #require((object["layers"] as? [[String: Any]])?.first)
        #expect((layer["basic"] as? [String: Any])?["exposure"] as? Double == -0.5)
        #expect((layer["mask"] as? [String: Any])?["kind"] as? String == "sky")
    }

    @Test("A sidecar holding only fields Proof knows has none unrecognized, including a null crop")
    func knownFieldsOnly() throws {
        let json = #"{"formatVersion": 1, "processVersion": 1, "basic": {"exposure": 1}, "look": null, "crop": null, "layers": []}"#
        #expect(try !Sidecar(data: Data(json.utf8)).hasUnrecognizedFields)
    }

    @Test("A sidecar from before look and crop were written as null reads the same and saves with them")
    func migratesOmittedNulls() throws {
        let json = #"{"formatVersion": 1, "processVersion": 1, "basic": {"exposure": 1}, "curve": {}, "layers": []}"#
        try Data(json.utf8).write(to: sidecarURL)
        let read = try #require(try Sidecar.read(for: photo))
        #expect(read.recipe == edited(exposure: 1))
        #expect(!read.hasUnrecognizedFields)

        try Sidecar.save(edited(exposure: 2), for: photo, over: read)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: sidecarURL)) as? [String: Any])
        #expect(object["crop"] is NSNull)
        #expect(object["look"] is NSNull)
    }

    @Test("Removing a crop removes it from the saved file")
    func removedCropIsRemoved() throws {
        var recipe = edited(exposure: 1)
        recipe.crop = Crop(x: 0.1, y: 0.1, width: 0.8, height: 0.8)
        let saved = try Sidecar.save(recipe, for: photo, over: nil)
        recipe.crop = nil
        try Sidecar.save(recipe, for: photo, over: saved)
        #expect(try Sidecar.read(for: photo)?.recipe.crop == nil)
    }

    @Test("Values are written as they were set, not rounded")
    func valuesWrittenExactly() throws {
        try Sidecar.save(edited(exposure: 0.3), for: photo, over: nil)
        let text = try String(contentsOf: sidecarURL, encoding: .utf8)
        #expect(text.contains(#""exposure" : 0.3,"#))
    }
}
