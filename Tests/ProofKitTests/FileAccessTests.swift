import Foundation
import Testing
@testable import ProofKit

/// Uses real bookmarks on temporary folders. They aren't security-scoped because the test
/// process isn't sandboxed; moves and renames are followed the same way either way.
@MainActor
struct FileAccessTests {
    let root: URL
    let storeURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileAccessTests-\(UUID().uuidString)")
        storeURL = root.appendingPathComponent("Support/locations.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func makeAccess(_ system: any BookmarkSystem = SystemBookmarks(securityScoped: false)) throws -> FileAccess {
        try FileAccess(storeURL: storeURL, system: system)
    }

    /// Creates `relativePath` under the test folder, with an empty file at the end.
    @discardableResult
    func makeFile(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("raw".utf8).write(to: url)
        return url
    }

    @Test("A saved folder and the photos in it reopen after relaunch")
    func survivesRelaunch() throws {
        let photo = try makeFile("Albums/L1000957.DNG")
        let added = try makeAccess().add(photo.deletingLastPathComponent())
        let reference = try #require(try makeAccess().reference(for: photo))

        let relaunched = try makeAccess()
        #expect(relaunched.locations == [added])
        #expect(relaunched.url(for: reference)?.lastPathComponent == "L1000957.DNG")
    }

    @Test("Photos in subfolders at any depth resolve through the parent folder's grant")
    func nestedPhotos() throws {
        try makeFile("Albums/top.DNG")
        let deep = try makeFile("Albums/2025/03/Trip/deep.DNG")
        let access = try makeAccess()
        let albums = try access.add(root.appendingPathComponent("Albums"))

        let reference = try #require(access.reference(for: deep))
        #expect(reference.locationID == albums.id)
        #expect(reference.relativePath == ["2025", "03", "Trip", "deep.DNG"])
        #expect(try makeAccess().url(for: reference) != nil)
    }

    @Test("Adding a saved folder again, or a folder inside it, makes no second grant")
    func noDuplicates() throws {
        try makeFile("Albums/2025/a.DNG")
        let access = try makeAccess()
        let albums = try access.add(root.appendingPathComponent("Albums"))

        #expect(try access.add(root.appendingPathComponent("Albums")) == albums)
        #expect(try access.add(root.appendingPathComponent("Albums/2025")) == albums)
        #expect(access.locations.count == 1)
    }

    @Test("When saved folders are nested, a photo belongs to the innermost one")
    func innermostWins() throws {
        let photo = try makeFile("Albums/2025/a.DNG")
        let access = try makeAccess()
        let year = try access.add(root.appendingPathComponent("Albums/2025"))
        let albums = try access.add(root.appendingPathComponent("Albums"))

        #expect(access.locations.count == 2)
        #expect(access.location(containing: photo)?.id == year.id)
        #expect(access.location(containing: root.appendingPathComponent("Albums/other.DNG"))?.id == albums.id)
    }

    @Test("Removing a location forgets the grant and leaves photos and sidecars on disk")
    func removeKeepsFiles() throws {
        let photo = try makeFile("Albums/a.DNG")
        let sidecar = try makeFile("Albums/a.DNG.proof")
        let access = try makeAccess()
        let albums = try access.add(photo.deletingLastPathComponent())
        let other = try access.add(try makeFile("Other/b.DNG").deletingLastPathComponent())
        _ = access.resolve(albums.id)

        try access.remove(albums.id)

        #expect(FileManager.default.fileExists(atPath: photo.path))
        #expect(FileManager.default.fileExists(atPath: sidecar.path))
        #expect(try makeAccess().locations == [other])
    }

    @Test("A folder renamed on the same volume is followed and its saved location updated")
    func followsRename() throws {
        try makeFile("Albums/a.DNG")
        let access = try makeAccess()
        let albums = try access.add(root.appendingPathComponent("Albums"))
        let renamed = root.appendingPathComponent("Albums 2025")
        try FileManager.default.moveItem(at: root.appendingPathComponent("Albums"), to: renamed)

        let relaunched = try makeAccess()
        guard case .available(let url) = relaunched.resolve(albums.id) else {
            Issue.record("The renamed folder didn't resolve")
            return
        }
        #expect(url.lastPathComponent == "Albums 2025")
        #expect(relaunched.locations.first?.name == "Albums 2025")
        #expect(relaunched.url(for: FileReference(locationID: albums.id, relativePath: ["a.DNG"])) != nil)
    }

    @Test("A folder moved into another folder is followed")
    func followsMove() throws {
        try makeFile("Albums/a.DNG")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Archive"), withIntermediateDirectories: true)
        let albums = try makeAccess().add(root.appendingPathComponent("Albums"))
        try FileManager.default.moveItem(at: root.appendingPathComponent("Albums"),
                                         to: root.appendingPathComponent("Archive/Albums"))

        let relaunched = try makeAccess()
        guard case .available(let url) = relaunched.resolve(albums.id) else {
            Issue.record("The moved folder didn't resolve")
            return
        }
        #expect(url.deletingLastPathComponent().lastPathComponent == "Archive")
    }

    @Test("A deleted folder is kept and marked missing, and relinking keeps its identifier")
    func missingAndRelink() throws {
        try makeFile("Albums/a.DNG")
        let albums = try makeAccess().add(root.appendingPathComponent("Albums"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("Albums"))

        let relaunched = try makeAccess()
        #expect(relaunched.resolve(albums.id) == .missing)
        #expect(relaunched.locations.map(\.id) == [albums.id])

        try makeFile("Restored/a.DNG")
        try relaunched.relink(albums.id, to: root.appendingPathComponent("Restored"))
        let reference = FileReference(locationID: albums.id, relativePath: ["a.DNG"])
        #expect(try makeAccess().url(for: reference) != nil)
        #expect(try makeAccess().locations.map(\.name) == ["Restored"])
    }

    @Test("A location on an unmounted volume is offline, not missing")
    func offlineVolume() throws {
        let system = FakeBookmarks(volume: URL(fileURLWithPath: "/Volumes/home"))
        let access = try makeAccess(system)
        let location = try access.add(URL(fileURLWithPath: "/Volumes/home/Albums"))

        system.unmounted = true
        #expect(try makeAccess(system).resolve(location.id) == .offline)
    }

    @Test("A stale bookmark is replaced with a fresh one")
    func refreshesStaleBookmark() throws {
        let system = FakeBookmarks(volume: nil)
        let location = try makeAccess(system).add(URL(fileURLWithPath: "/Photos"))

        system.stale = true
        let access = try makeAccess(system)
        #expect(access.resolve(location.id) == .available(URL(fileURLWithPath: "/Photos")))
        #expect(access.locations.first?.bookmark != location.bookmark)
        #expect(try makeAccess(system).locations.first?.bookmark == access.locations.first?.bookmark)
    }

    @Test("Access to a resolved location is released when it is removed")
    func releasesAccess() throws {
        let system = FakeBookmarks(volume: nil)
        let access = try makeAccess(system)
        let location = try access.add(URL(fileURLWithPath: "/Photos"))
        _ = access.resolve(location.id)
        #expect(system.accessCount == 1)

        try access.remove(location.id)
        #expect(system.accessCount == 0)
    }
}

/// Stands in for situations a test can't create with real disks, such as an unmounted NAS.
final class FakeBookmarks: BookmarkSystem {
    let volume: URL?
    var unmounted = false
    var stale = false
    var accessCount = 0
    private var generation = 0

    init(volume: URL?) {
        self.volume = volume
    }

    func bookmarkData(for url: URL) throws -> Data {
        generation += 1
        return Data("\(url.path)|\(generation)".utf8)
    }

    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        if unmounted { throw CocoaError(.fileNoSuchFile) }
        let path = String(decoding: data, as: UTF8.self).split(separator: "|")[0]
        return (URL(fileURLWithPath: String(path)), stale)
    }

    func startAccessing(_ url: URL) -> Bool {
        accessCount += 1
        return true
    }

    func stopAccessing(_ url: URL) {
        accessCount -= 1
    }

    func volumeURL(of url: URL) -> URL? { volume }

    func exists(_ url: URL) -> Bool {
        !(unmounted && volume.map { url.path.hasPrefix($0.path) } == true)
    }
}
