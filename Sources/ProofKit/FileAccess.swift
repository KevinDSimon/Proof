import Foundation

/// A folder or file the person granted access to, remembered across launches.
/// The identifier never changes, including when the location is relinked, so anything
/// that refers to a location by `id` stays attached to it.
public struct SavedLocation: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var bookmark: Data
    /// Where the location was the last time it resolved. Shown while it is missing.
    public var lastKnownURL: URL
    /// The volume it lives on. `nil` or `/` means the startup disk.
    public var volumeURL: URL?
    /// Whether the grant lets Proof write sidecars here. Locations saved before Proof wrote
    /// anything have read-only grants and need to be granted once more (decision 0007).
    public var canWrite: Bool

    public init(id: UUID, name: String, bookmark: Data, lastKnownURL: URL, volumeURL: URL?, canWrite: Bool) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.lastKnownURL = lastKnownURL
        self.volumeURL = volumeURL
        self.canWrite = canWrite
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        bookmark = try c.decode(Data.self, forKey: .bookmark)
        lastKnownURL = try c.decode(URL.self, forKey: .lastKnownURL)
        volumeURL = try c.decodeIfPresent(URL.self, forKey: .volumeURL)
        canWrite = try c.decodeIfPresent(Bool.self, forKey: .canWrite) ?? false
    }
}

public enum FileAccessError: Error, LocalizedError, Equatable {
    /// A write grant was offered for a different folder than the saved location.
    case notTheSavedLocation(name: String)

    public var errorDescription: String? {
        switch self {
        case .notTheSavedLocation(let name): "Choose the folder “\(name)” to let Proof save in it."
        }
    }
}

/// Whether a saved location can be read right now.
public enum LocationStatus: Equatable, Sendable {
    case available(URL)
    /// Its volume, such as a NAS share, isn't mounted. Nothing is wrong with the grant.
    case offline
    /// The grant no longer leads anywhere. The location is kept so it can be relinked.
    case missing
}

/// A file inside a saved location, stored as the location's identifier and a relative path,
/// so it keeps working after the location is moved, renamed or relinked.
public struct FileReference: Codable, Hashable, Sendable {
    public var locationID: UUID
    /// Path components below the location; empty when the location is the file itself.
    public var relativePath: [String]

    public init(locationID: UUID, relativePath: [String]) {
        self.locationID = locationID
        self.relativePath = relativePath
    }
}

/// How grants are turned into bookmarks and back. The Mac uses security-scoped bookmarks;
/// the iOS app can supply one for folders picked in the Files app.
public protocol BookmarkSystem {
    func bookmarkData(for url: URL) throws -> Data
    func resolve(_ data: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func volumeURL(of url: URL) -> URL?
    func exists(_ url: URL) -> Bool
}

/// Bookmarks from Foundation. Security-scoped on the Mac, where the sandbox requires it.
public struct SystemBookmarks: BookmarkSystem {
    let securityScoped: Bool

    public init(securityScoped: Bool = true) {
        self.securityScoped = securityScoped
    }

    public func bookmarkData(for url: URL) throws -> Data {
        // A URL from an Open dialog only grants access while it is held.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        return try url.bookmarkData(options: creationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    public func resolve(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        // Without mounting, an unmounted NAS fails fast instead of stalling the launch.
        let url = try URL(resolvingBookmarkData: data, options: resolutionOptions,
                          relativeTo: nil, bookmarkDataIsStale: &isStale)
        return (url, isStale)
    }

    public func startAccessing(_ url: URL) -> Bool {
        securityScoped ? url.startAccessingSecurityScopedResource() : true
    }

    public func stopAccessing(_ url: URL) {
        if securityScoped { url.stopAccessingSecurityScopedResource() }
    }

    public func volumeURL(of url: URL) -> URL? {
        try? url.resourceValues(forKeys: [.volumeURLKey]).volume
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private var creationOptions: URL.BookmarkCreationOptions {
        #if os(macOS)
        securityScoped ? [.withSecurityScope] : []
        #else
        []
        #endif
    }

    private var resolutionOptions: URL.BookmarkResolutionOptions {
        #if os(macOS)
        securityScoped ? [.withSecurityScope, .withoutUI, .withoutMounting] : [.withoutUI, .withoutMounting]
        #else
        [.withoutUI, .withoutMounting]
        #endif
    }
}

/// The one place that grants, stores and resolves access to folders and files.
/// Nothing else creates or resolves bookmarks. Removing a location only forgets the grant;
/// it never touches photos, sidecars or edits on disk.
@MainActor
public final class FileAccess {
    public private(set) var locations: [SavedLocation]

    private let storeURL: URL
    private let system: any BookmarkSystem
    /// Resolved locations whose access is held, so their files stay readable.
    private var accessed: [UUID: URL] = [:]

    /// Loads the saved locations from `storeURL`, a JSON file that is created on first save.
    public init(storeURL: URL, system: any BookmarkSystem = SystemBookmarks()) throws {
        self.storeURL = storeURL
        self.system = system
        if FileManager.default.fileExists(atPath: storeURL.path) {
            locations = try JSONDecoder().decode([SavedLocation].self, from: Data(contentsOf: storeURL))
        } else {
            locations = []
        }
    }

    /// Saves a grant for `url`. If a saved location already is or contains `url`,
    /// that location is returned and no second grant is made.
    @discardableResult
    public func add(_ url: URL) throws -> SavedLocation {
        if let existing = location(containing: url) { return existing }
        let location = SavedLocation(
            id: UUID(),
            name: url.lastPathComponent,
            bookmark: try system.bookmarkData(for: url),
            lastKnownURL: url,
            volumeURL: system.volumeURL(of: url),
            canWrite: true
        )
        locations.append(location)
        try save()
        return location
    }

    /// Forgets a location's grant. Files on disk are left as they are.
    public func remove(_ id: UUID) throws {
        endAccess(id)
        locations.removeAll { $0.id == id }
        try save()
    }

    /// Points a missing location at a new folder or file, keeping its identifier.
    public func relink(_ id: UUID, to url: URL) throws {
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
        endAccess(id)
        locations[index].bookmark = try system.bookmarkData(for: url)
        locations[index].lastKnownURL = url
        locations[index].name = url.lastPathComponent
        locations[index].volumeURL = system.volumeURL(of: url)
        locations[index].canWrite = true
        try save()
    }

    /// Replaces a read-only grant with a read-write one. `url` must be the location itself,
    /// as chosen again by the person; any other folder is refused and nothing changes.
    public func grantWriteAccess(_ id: UUID, with url: URL) throws {
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
        let current = accessed[id] ?? locations[index].lastKnownURL
        guard Self.components(of: url) == Self.components(of: current) else {
            throw FileAccessError.notTheSavedLocation(name: locations[index].name)
        }
        endAccess(id)
        locations[index].bookmark = try system.bookmarkData(for: url)
        locations[index].canWrite = true
        try save()
    }

    /// Whether Proof may write next to `url`, such as a sidecar beside a photo.
    public func canWrite(to url: URL) -> Bool {
        location(containing: url)?.canWrite ?? false
    }

    /// Resolves a location and holds access to it. A location that moved or was renamed
    /// is followed and its bookmark refreshed.
    public func resolve(_ id: UUID) -> LocationStatus {
        if let url = accessed[id] { return .available(url) }
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return .missing }
        let location = locations[index]

        guard let (url, isStale) = try? system.resolve(location.bookmark), system.exists(url) else {
            return isOffline(location) ? .offline : .missing
        }
        guard system.startAccessing(url) else { return .missing }
        accessed[id] = url

        if isStale || url.standardizedFileURL != location.lastKnownURL.standardizedFileURL {
            if isStale, let fresh = try? system.bookmarkData(for: url) {
                locations[index].bookmark = fresh
            }
            locations[index].lastKnownURL = url
            locations[index].name = url.lastPathComponent
            try? save()
        }
        return .available(url)
    }

    /// Resolves a location again after a drive or network share connects or disconnects. Access
    /// held to a location that is no longer there is released first, so it can become `offline`.
    public func recheck(_ id: UUID) -> LocationStatus {
        if let url = accessed[id], !system.exists(url) { endAccess(id) }
        return resolve(id)
    }

    /// The saved location that is or contains `url`. When saved locations are nested,
    /// the innermost one wins.
    public func location(containing url: URL) -> SavedLocation? {
        let target = Self.components(of: url)
        return locations
            .filter { target.starts(with: Self.components(of: $0.lastKnownURL)) }
            .max { Self.components(of: $0.lastKnownURL).count < Self.components(of: $1.lastKnownURL).count }
    }

    /// A reference to `url` that survives the location moving. `nil` if no saved location contains it.
    public func reference(for url: URL) -> FileReference? {
        guard let location = location(containing: url) else { return nil }
        let relative = Self.components(of: url).dropFirst(Self.components(of: location.lastKnownURL).count)
        return FileReference(locationID: location.id, relativePath: Array(relative))
    }

    /// The current URL for a reference, resolving its location. `nil` if the location
    /// isn't available or the file is no longer inside it.
    public func url(for reference: FileReference) -> URL? {
        guard case .available(let root) = resolve(reference.locationID) else { return nil }
        let url = reference.relativePath.reduce(root) { $0.appendingPathComponent($1) }
        return system.exists(url) ? url : nil
    }

    private func endAccess(_ id: UUID) {
        if let url = accessed.removeValue(forKey: id) { system.stopAccessing(url) }
    }

    /// A location on another volume whose volume isn't mounted is offline rather than missing.
    private func isOffline(_ location: SavedLocation) -> Bool {
        guard let volume = location.volumeURL, volume.path != "/" else { return false }
        return !system.exists(volume)
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(locations).write(to: storeURL, options: .atomic)
    }

    /// Path components with symlinks resolved, so `/var` and `/private/var` compare equal.
    private static func components(of url: URL) -> [String] {
        url.standardizedFileURL.resolvingSymlinksInPath().pathComponents
    }
}
