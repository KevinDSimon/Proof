import Foundation
import Testing
@testable import ProofKit

/// Uses real bookmarks on temporary folders, not security-scoped, as `FileAccessTests` does.
@MainActor
struct ExportDestinationsTests {
    let root: URL
    let storeURL: URL
    let fileAccess: FileAccess

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportDestinationsTests-\(UUID().uuidString)")
        storeURL = root.appendingPathComponent("Support/export-destinations.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileAccess = try FileAccess(storeURL: root.appendingPathComponent("Support/locations.json"),
                                    system: SystemBookmarks(securityScoped: false))
    }

    func makeDestinations() throws -> ExportDestinations {
        try ExportDestinations(storeURL: storeURL, fileAccess: fileAccess)
    }

    func makeFolder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A saved destination keeps its name, folder and settings after relaunch")
    func survivesRelaunch() throws {
        let folder = try makeFolder("Instagram")
        let settings = ExportSettings(format: .heic, size: .longEdge, longEdge: 1080, colorSpace: .displayP3)
        let added = try makeDestinations().add(name: "Phone", folder: folder, settings: settings)

        let relaunched = try makeDestinations()
        #expect(relaunched.destinations == [added])
        #expect(relaunched.destination(added.id)?.settings == settings)
        #expect(relaunched.folder(of: added.id)?.lastPathComponent == "Instagram")
    }

    @Test("A destination saved without a name is named after its folder")
    func defaultName() throws {
        let destinations = try makeDestinations()
        let added = try destinations.add(name: "  ", folder: try makeFolder("Prints"), settings: ExportSettings())
        #expect(added.name == "Prints")

        try destinations.rename(added.id, to: "")
        #expect(destinations.destination(added.id)?.name == "Prints")
        try destinations.rename(added.id, to: "Lab")
        #expect(try makeDestinations().destination(added.id)?.name == "Lab")
    }

    @Test("Updating a destination's settings or folder keeps its identity and name")
    func updates() throws {
        let destinations = try makeDestinations()
        let added = try destinations.add(name: "Print", folder: try makeFolder("A"), settings: ExportSettings())
        try destinations.update(added.id, settings: ExportSettings(format: .tiff))
        try destinations.changeFolder(of: added.id, to: try makeFolder("B"))

        let relaunched = try makeDestinations()
        let saved = try #require(relaunched.destination(added.id))
        #expect(saved.name == "Print")
        #expect(saved.settings.format == .tiff)
        #expect(relaunched.folder(of: added.id)?.lastPathComponent == "B")
    }

    @Test("A destination's folder is followed after it is renamed")
    func followsRename() throws {
        let folder = try makeFolder("Exports")
        let destinations = try makeDestinations()
        let added = try destinations.add(name: "Web", folder: folder, settings: ExportSettings())
        try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("Web Exports"))

        #expect(destinations.folder(of: added.id)?.lastPathComponent == "Web Exports")
        #expect(try makeDestinations().destination(added.id)?.lastKnownURL.lastPathComponent == "Web Exports")
    }

    @Test("A destination whose folder was deleted has no folder, and removing it leaves other folders alone")
    func missingAndRemoved() throws {
        let gone = try makeFolder("Gone")
        let kept = try makeFolder("Kept")
        let destinations = try makeDestinations()
        let missing = try destinations.add(name: "Gone", folder: gone, settings: ExportSettings())
        let other = try destinations.add(name: "Kept", folder: kept, settings: ExportSettings())
        try FileManager.default.removeItem(at: gone)

        #expect(destinations.folder(of: missing.id) == nil)
        try destinations.remove(other.id)
        #expect(try makeDestinations().destinations.map(\.id) == [missing.id])
        #expect(FileManager.default.fileExists(atPath: kept.path))
    }
}
