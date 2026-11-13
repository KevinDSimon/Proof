import Foundation
import Observation

/// A folder to export to and the settings to export with, saved under a name the person gives it,
/// so exporting there needs no folder dialog (decision 0032).
public struct ExportDestination: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var bookmark: Data
    /// Where the folder was the last time it resolved. Shown in the export sheet, and while it is missing.
    public var lastKnownURL: URL
    public var settings: ExportSettings

    public init(id: UUID = UUID(), name: String, bookmark: Data, lastKnownURL: URL, settings: ExportSettings) {
        self.id = id
        self.name = name
        self.bookmark = bookmark
        self.lastKnownURL = lastKnownURL
        self.settings = settings
    }
}

/// The saved export destinations, in the order they were added, stored as JSON. Grants for their
/// folders are made and resolved by `FileAccess`.
@Observable @MainActor
public final class ExportDestinations {
    public private(set) var destinations: [ExportDestination]

    @ObservationIgnored private let storeURL: URL
    @ObservationIgnored private let fileAccess: FileAccess

    /// Loads the destinations from `storeURL`, a JSON file that is created on first save.
    public init(storeURL: URL, fileAccess: FileAccess) throws {
        self.storeURL = storeURL
        self.fileAccess = fileAccess
        if FileManager.default.fileExists(atPath: storeURL.path) {
            destinations = try JSONDecoder().decode([ExportDestination].self, from: Data(contentsOf: storeURL))
        } else {
            destinations = []
        }
    }

    public func destination(_ id: UUID) -> ExportDestination? {
        destinations.first { $0.id == id }
    }

    /// Saves `folder`, a folder the person just chose, with `settings`. An empty name becomes the
    /// folder's name.
    @discardableResult
    public func add(name: String, folder: URL, settings: ExportSettings) throws -> ExportDestination {
        let destination = ExportDestination(name: Self.name(name, or: folder), bookmark: try fileAccess.folderBookmark(for: folder),
                                            lastKnownURL: folder, settings: settings)
        destinations.append(destination)
        try save()
        return destination
    }

    /// An empty name keeps the old one.
    public func rename(_ id: UUID, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = index(of: id), !trimmed.isEmpty else { return }
        destinations[index].name = trimmed
        try save()
    }

    public func update(_ id: UUID, settings: ExportSettings) throws {
        guard let index = index(of: id) else { return }
        destinations[index].settings = settings
        try save()
    }

    /// Points a destination at another folder, keeping its name and settings.
    public func changeFolder(of id: UUID, to folder: URL) throws {
        guard let index = index(of: id) else { return }
        destinations[index].bookmark = try fileAccess.folderBookmark(for: folder)
        destinations[index].lastKnownURL = folder
        try save()
    }

    /// Forgets the destination. Its folder and the files in it are left as they are.
    public func remove(_ id: UUID) throws {
        destinations.removeAll { $0.id == id }
        try save()
    }

    /// The destination's folder now, following it if it moved or was renamed. `nil` when it can't
    /// be found, such as on a drive that isn't connected. The caller starts and stops access.
    public func folder(of id: UUID) -> URL? {
        guard let index = index(of: id),
              let (url, fresh) = fileAccess.resolveFolderBookmark(destinations[index].bookmark) else { return nil }
        if fresh != nil || url.standardizedFileURL != destinations[index].lastKnownURL.standardizedFileURL {
            if let fresh { destinations[index].bookmark = fresh }
            destinations[index].lastKnownURL = url
            try? save()
        }
        return url
    }

    private func index(of id: UUID) -> Int? {
        destinations.firstIndex { $0.id == id }
    }

    private static func name(_ name: String, or folder: URL) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? folder.lastPathComponent : trimmed
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(destinations).write(to: storeURL, options: .atomic)
    }
}
