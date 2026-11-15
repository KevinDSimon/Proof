import Foundation
import ImageIO
import Testing
@testable import ProofKit

/// The fingerprint a sidecar stores of its original, and relinking a sidecar after its photo was
/// renamed (decision 0007). The test photos aren't real RAW files, so their fingerprint is their size.
struct SidecarRelinkTests {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SidecarRelinkTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    @discardableResult
    func photo(_ name: String, size: Int) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 1, count: size).write(to: url)
        return url
    }

    func edited(exposure: Double) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.basic.exposure = exposure
        return recipe
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    /// Writes an edit for `name`, then renames the photo to `newName`, as Finder would.
    func rename(_ name: String, to newName: String) throws {
        try FileManager.default.moveItem(at: folder.appendingPathComponent(name),
                                         to: folder.appendingPathComponent(newName))
    }

    @Test("A new sidecar stores the size of its original")
    func newSidecarStoresFingerprint() throws {
        let url = try photo("L1000957.DNG", size: 100)
        let saved = try Sidecar.save(edited(exposure: 1), for: url, over: nil)
        #expect(saved?.original == OriginalFingerprint(size: 100))
        #expect(try Sidecar.read(for: url)?.original == OriginalFingerprint(size: 100))
        #expect(saved?.hasUnrecognizedFields == false)
    }

    @Test("A sidecar written before fingerprints reads without one and gains one on its next save")
    func migratesSidecarWithoutFingerprint() throws {
        let url = try photo("L1000957.DNG", size: 100)
        let json = #"{"formatVersion": 3, "processVersion": 1, "basic": {"exposure": 1}, "look": null, "crop": null, "layers": []}"#
        try Data(json.utf8).write(to: EditRecipe.sidecarURL(for: url))
        let read = try #require(try Sidecar.read(for: url))
        #expect(read.original == nil)
        #expect(!read.hasUnrecognizedFields)

        try Sidecar.save(edited(exposure: 2), for: url, over: read)
        let saved = try #require(try Sidecar.read(for: url))
        #expect(saved.original == OriginalFingerprint(size: 100))
        #expect(saved.recipe == edited(exposure: 2))
    }

    @Test("A saved fingerprint stays as first written when the edit changes")
    func fingerprintIsKept() throws {
        let url = try photo("L1000957.DNG", size: 100)
        let first = try Sidecar.save(edited(exposure: 1), for: url, over: nil)
        try Data(repeating: 1, count: 200).write(to: url)
        let second = try Sidecar.save(edited(exposure: 2), for: url, over: first)
        #expect(second?.original == OriginalFingerprint(size: 100))
    }

    @Test("A sidecar whose only extra field is the fingerprint is still deleted when the edit is neutral")
    func fingerprintDoesNotBlockDeletion() throws {
        let url = try photo("L1000957.DNG", size: 100)
        let saved = try Sidecar.save(edited(exposure: 1), for: url, over: nil)
        #expect(try Sidecar.save(EditRecipe(), for: url, over: saved) == nil)
        #expect(!exists("L1000957.DNG.proof"))
    }

    @Test("A sidecar follows its photo when the photo is renamed in the same folder")
    func relinksRenamedPhoto() throws {
        try Sidecar.save(edited(exposure: 1), for: photo("L1000957.DNG", size: 100), over: nil)
        try photo("L1000958.DNG", size: 120)
        try rename("L1000957.DNG", to: "Coast.DNG")

        #expect(try Sidecar.relink(in: folder) == ["Coast.DNG": "L1000957.DNG"])
        #expect(!exists("L1000957.DNG.proof"))
        #expect(try Sidecar.read(for: folder.appendingPathComponent("Coast.DNG"))?.recipe == edited(exposure: 1))
        #expect(!exists("L1000958.DNG.proof"))
    }

    @Test("Several renamed photos each get their own sidecar back")
    func relinksSeveral() throws {
        try Sidecar.save(edited(exposure: 1), for: photo("A.DNG", size: 100), over: nil)
        try Sidecar.save(edited(exposure: 2), for: photo("B.DNG", size: 200), over: nil)
        try rename("A.DNG", to: "Coast 1.DNG")
        try rename("B.DNG", to: "Coast 2.DNG")

        try Sidecar.relink(in: folder)
        #expect(try Sidecar.read(for: folder.appendingPathComponent("Coast 1.DNG"))?.recipe == edited(exposure: 1))
        #expect(try Sidecar.read(for: folder.appendingPathComponent("Coast 2.DNG"))?.recipe == edited(exposure: 2))
    }

    @Test("A sidecar that matches two photos is left alone")
    func ambiguousMatchIsLeftAlone() throws {
        try Sidecar.save(edited(exposure: 1), for: photo("L1000957.DNG", size: 100), over: nil)
        try photo("Other.DNG", size: 100)
        try rename("L1000957.DNG", to: "Coast.DNG")

        #expect(try Sidecar.relink(in: folder).isEmpty)
        #expect(exists("L1000957.DNG.proof"))
        #expect(!exists("Coast.DNG.proof"))
        #expect(!exists("Other.DNG.proof"))
    }

    @Test("Two sidecars that match the same photo are both left alone")
    func twoSidecarsForOnePhotoAreLeftAlone() throws {
        try Sidecar.save(edited(exposure: 1), for: photo("A.DNG", size: 100), over: nil)
        try Sidecar.save(edited(exposure: 2), for: photo("B.DNG", size: 100), over: nil)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("A.DNG"))
        try rename("B.DNG", to: "Coast.DNG")

        #expect(try Sidecar.relink(in: folder).isEmpty)
        #expect(exists("A.DNG.proof"))
        #expect(exists("B.DNG.proof"))
    }

    @Test("A photo with its own sidecar never takes another one")
    func photoWithSidecarIsSkipped() throws {
        try Sidecar.save(edited(exposure: 1), for: photo("A.DNG", size: 100), over: nil)
        try Sidecar.save(edited(exposure: 2), for: photo("B.DNG", size: 100), over: nil)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("A.DNG"))

        #expect(try Sidecar.relink(in: folder).isEmpty)
        #expect(try Sidecar.read(for: folder.appendingPathComponent("B.DNG"))?.recipe == edited(exposure: 2))
    }

    @Test("A sidecar without a fingerprint, or with no matching photo, is left alone")
    func unmatchedIsLeftAlone() throws {
        let json = #"{"formatVersion": 3, "processVersion": 1, "basic": {"exposure": 1}, "layers": []}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("Old.DNG.proof"))
        try Sidecar.save(edited(exposure: 1), for: photo("Deleted.DNG", size: 300), over: nil)
        try FileManager.default.removeItem(at: folder.appendingPathComponent("Deleted.DNG"))
        try photo("Coast.DNG", size: 100)

        #expect(try Sidecar.relink(in: folder).isEmpty)
        #expect(exists("Old.DNG.proof"))
        #expect(exists("Deleted.DNG.proof"))
    }

    @Test("The fingerprint reads the capture time with subseconds and the raw data ID")
    func fingerprintFromProperties() {
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2025:06:01 14:03:22",
                kCGImagePropertyExifSubsecTimeOriginal: "417",
                kCGImagePropertyExifImageUniqueID: "ABC123",
            ] as [CFString: Any],
            kCGImagePropertyDNGDictionary: [
                kCGImagePropertyDNGRawDataUniqueID: [0x0a, 0xff, 0, 1].map { NSNumber(value: $0) },
            ] as [CFString: Any],
        ]
        let fingerprint = OriginalFingerprint(size: 5, properties: properties)
        #expect(fingerprint == OriginalFingerprint(size: 5, captureTime: "2025:06:01 14:03:22.417", uniqueID: "0aff0001"))
    }

    @Test("Without a raw data ID the fingerprint uses the image ID, and the capture time can lack subseconds")
    func fingerprintFallsBackToImageID() {
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifDateTimeOriginal: "2025:06:01 14:03:22",
                kCGImagePropertyExifImageUniqueID: "ABC123",
            ] as [CFString: Any],
        ]
        #expect(OriginalFingerprint(size: 5, properties: properties)
            == OriginalFingerprint(size: 5, captureTime: "2025:06:01 14:03:22", uniqueID: "ABC123"))
    }
}
