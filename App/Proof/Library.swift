import Foundation
import Observation
import ProofKit

/// The saved folders, what has been read of them, which folder, filter and photo are chosen, and
/// whether that photo is being edited. Shared by the sidebar, the grid, the toolbar and the menus.
@Observable @MainActor
final class Library {
    /// Why the folder picker is open.
    enum FolderRequest {
        case add
        case locate(SavedLocation)
    }

    private(set) var locations: [SavedLocation] = []
    private(set) var statuses: [UUID: LocationStatus] = [:]
    /// Folders read so far. A folder that couldn't be read is stored empty.
    private(set) var contents: [FileReference: FolderContents] = [:]
    var selection: FileReference? {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(selection), forKey: Self.selectionKey)
            if selection != oldValue {
                browse = BrowseState()
                readEmbeddedMetadata()
            }
        }
    }
    var filter: PhotoFilter = .all {
        didSet { browse.keep(only: visiblePhotos) }
    }
    var browse = BrowseState()
    var isInspectorShown = true
    var isChoosingFolder = false
    /// Kept apart from `isChoosingFolder`, which SwiftUI clears before the picker's result arrives.
    private(set) var folderRequest: FolderRequest = .add
    var errorMessage: String?

    private let fileAccess: FileAccess?
    private var metadataTask: Task<Void, Never>?
    private static let selectionKey = "selectedFolder"

    init() {
        fileAccess = try? FileAccess(storeURL: URL.applicationSupportDirectory
            .appendingPathComponent("Proof/locations.json"))
        if fileAccess == nil { errorMessage = "Proof couldn't load its saved folders." }
        refreshLocations()
        selection = UserDefaults.standard.data(forKey: Self.selectionKey)
            .flatMap { try? JSONDecoder().decode(FileReference.self, from: $0) }
    }

    func status(of id: UUID) -> LocationStatus {
        statuses[id] ?? .missing
    }

    /// The selected folder's photos that pass the filter.
    var visiblePhotos: [FolderContents.Photo] {
        guard let selection, let contents = contents[selection] else { return [] }
        return contents.photos.filter(filter.includes)
    }

    /// Reads a folder off the main thread. Already-read folders are read again only when `force` is set.
    func load(_ folder: FileReference, force: Bool = false) async {
        guard force || contents[folder] == nil else { return }
        guard let url = fileAccess?.url(for: folder) else { return }
        let read = await Task.detached { try? FolderContents.read(at: url) }.value
        contents[folder] = read ?? FolderContents(subfolders: [], photos: [])
        if folder == selection {
            browse.keep(only: visiblePhotos)
            readEmbeddedMetadata()
        }
    }

    /// Reads ratings from inside the selected folder's photos that have no XMP sidecar. Only the
    /// selected folder is read, because the sidebar loads every visible folder and opening each
    /// photo on a NAS is slow.
    private func readEmbeddedMetadata() {
        metadataTask?.cancel()
        guard let folder = selection, let photos = contents[folder]?.photos else { return }
        let missing = photos.filter { $0.metadata == nil }.compactMap { photo in
            url(ofPhoto: photo.name, in: folder).map { (name: photo.name, url: $0) }
        }
        guard !missing.isEmpty else { return }
        metadataTask = Task {
            for await batch in FolderContents.embeddedMetadata(of: missing) {
                contents[folder]?.setMetadata(batch)
                if folder == selection { browse.keep(only: visiblePhotos) }
            }
        }
    }

    var isEditing: Bool { browse.mode == .editing }

    /// The file of the selected photo.
    var selectedPhotoURL: URL? {
        guard let selection, let name = browse.selectedPhoto else { return nil }
        return url(ofPhoto: name, in: selection)
    }

    /// The file for a photo listed in `folder`. A saved location that is a single photo is its own folder.
    func url(ofPhoto name: String, in folder: FileReference) -> URL? {
        guard let fileAccess, let folderURL = fileAccess.url(for: folder) else { return nil }
        let isDirectory = (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard isDirectory else { return folderURL }
        return fileAccess.url(for: FileReference(locationID: folder.locationID,
                                                 relativePath: folder.relativePath + [name]))
    }

    func requestFolder(_ request: FolderRequest) {
        folderRequest = request
        isChoosingFolder = true
    }

    func chose(_ url: URL) {
        guard let fileAccess else { return }
        do {
            switch folderRequest {
            case .add:
                try fileAccess.add(url)
                refreshLocations()
                selection = fileAccess.reference(for: url)
            case .locate(let location):
                try fileAccess.relink(location.id, to: url)
                contents = contents.filter { $0.key.locationID != location.id }
                refreshLocations()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forgets a saved folder. Photos and edits on disk are not touched.
    func remove(_ location: SavedLocation) {
        do {
            try fileAccess?.remove(location.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        contents = contents.filter { $0.key.locationID != location.id }
        if selection?.locationID == location.id { selection = nil }
        refreshLocations()
    }

    private func refreshLocations() {
        guard let fileAccess else { return }
        locations = fileAccess.locations
        // Resolving never mounts a volume, so this doesn't wait on a disconnected NAS.
        statuses = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, fileAccess.resolve($0.id)) })
    }
}
