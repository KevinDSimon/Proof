import Foundation
import Observation
import ProofKit

/// What the sidebar can select: All Photos, or one folder.
enum SidebarItem: Codable, Hashable {
    case allPhotos
    case folder(FileReference)

    var folder: FileReference? {
        if case .folder(let folder) = self { folder } else { nil }
    }
}

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
    var selection: SidebarItem? {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(selection), forKey: Self.selectionKey)
            if selection != oldValue {
                changedPhotos = []
                browse = BrowseState()
                readAllPhotos()
                readEmbeddedMetadata()
            }
        }
    }
    /// While All Photos is selected, whether folders under the saved locations are still being read.
    private(set) var isReadingAllPhotos = false
    var filter: PhotoFilter = .all {
        didSet {
            changedPhotos = []
            browse.keep(only: visiblePhotos)
        }
    }
    var browse = BrowseState()
    var isInspectorShown = true
    var isChoosingFolder = false
    /// Kept apart from `isChoosingFolder`, which SwiftUI clears before the picker's result arrives.
    private(set) var folderRequest: FolderRequest = .add
    var errorMessage: String?

    private let fileAccess: FileAccess?
    private var metadataTask: Task<Void, Never>?
    private var allPhotosTask: Task<Void, Never>?
    /// Photos whose rating or flag was changed since the filter or folder last changed. They stay
    /// visible even if the filter no longer matches, so a photo doesn't vanish while it's rated.
    private var changedPhotos: Set<PhotoReference> = []
    private static let selectionKey = "selectedFolder"

    init() {
        fileAccess = try? FileAccess(storeURL: URL.applicationSupportDirectory
            .appendingPathComponent("Proof/locations.json"))
        if fileAccess == nil { errorMessage = "Proof couldn't load its saved folders." }
        refreshLocations()
        // Before All Photos, the selection was saved as a folder reference.
        selection = UserDefaults.standard.data(forKey: Self.selectionKey).flatMap { data in
            (try? JSONDecoder().decode(SidebarItem.self, from: data))
                ?? (try? JSONDecoder().decode(FileReference.self, from: data)).map(SidebarItem.folder)
        }
    }

    func status(of id: UUID) -> LocationStatus {
        statuses[id] ?? .missing
    }

    /// The selected folder's photos, or for All Photos every photo read so far under the available
    /// locations, in sidebar order.
    var listedPhotos: [ListedPhoto] {
        switch selection {
        case .folder(let folder): ListedPhoto.photos(of: folder, in: contents)
        case .allPhotos: availableRoots.flatMap { ListedPhoto.photos(under: $0, in: contents) }
        case nil: []
        }
    }

    /// The listed photos that pass the filter.
    var visiblePhotos: [ListedPhoto] {
        listedPhotos.filter { filter.includes($0.photo) || changedPhotos.contains($0.id) }
    }

    /// Saved locations All Photos leaves out because their drive isn't connected or they can't be found.
    var unavailableLocations: [SavedLocation] {
        locations.filter { !isAvailable($0) }
    }

    private var availableRoots: [FileReference] {
        locations.filter(isAvailable)
            .map { FileReference(locationID: $0.id, relativePath: []) }
    }

    private func isAvailable(_ location: SavedLocation) -> Bool {
        if case .available = status(of: location.id) { true } else { false }
    }

    /// A folder's name as the sidebar shows it: its own name, or the saved location's.
    func name(of folder: FileReference) -> String {
        folder.relativePath.last ?? locations.first { $0.id == folder.locationID }?.name ?? ""
    }

    /// Where a folder sits under its saved location, as in "NAS › Albums › Coast".
    func path(of folder: FileReference) -> String {
        let location = locations.first { $0.id == folder.locationID }?.name
        return ([location].compactMap { $0 } + folder.relativePath).joined(separator: " › ")
    }

    /// Reads a folder off the main thread. Already-read folders are read again only when `force` is set.
    func load(_ folder: FileReference, force: Bool = false) async {
        guard force || contents[folder] == nil else { return }
        guard let url = fileAccess?.url(for: folder) else { return }
        let read = await Task.detached { try? FolderContents.read(at: url) }.value
        contents[folder] = read ?? FolderContents(subfolders: [], photos: [])
        if .folder(folder) == selection {
            browse.keep(only: visiblePhotos)
            readEmbeddedMetadata()
        }
    }

    /// For All Photos, reads every folder under the available locations, one at a time and in
    /// sidebar order, so the grid fills in folder by folder. Folders the sidebar already read are
    /// not read again. Reading stops when another item is selected.
    private func readAllPhotos() {
        allPhotosTask?.cancel()
        isReadingAllPhotos = false
        guard selection == .allPhotos else { return }
        isReadingAllPhotos = true
        let roots = availableRoots
        allPhotosTask = Task {
            for root in roots { await loadTree(root) }
            guard !Task.isCancelled else { return }
            isReadingAllPhotos = false
            browse.keep(only: visiblePhotos)
            readEmbeddedMetadata()
        }
    }

    private func loadTree(_ folder: FileReference) async {
        guard !Task.isCancelled else { return }
        await load(folder)
        for subfolder in contents[folder]?.subfolders ?? [] {
            await loadTree(FileReference(locationID: folder.locationID, relativePath: folder.relativePath + [subfolder]))
        }
    }

    /// Reads ratings from inside the listed photos that have no XMP sidecar, folder by folder.
    /// Only what is selected is read, because the sidebar loads every visible folder and opening
    /// each photo on a NAS is slow.
    private func readEmbeddedMetadata() {
        metadataTask?.cancel()
        let shown = selection
        let missing = Dictionary(grouping: listedPhotos.filter { $0.photo.metadata == nil }, by: \.folder)
        let folders = listedPhotos.map(\.folder).reduce(into: [FileReference]()) { order, folder in
            if missing[folder] != nil, order.last != folder { order.append(folder) }
        }
        guard !folders.isEmpty else { return }
        metadataTask = Task {
            for folder in folders {
                let photos = (missing[folder] ?? []).compactMap { photo in
                    url(ofPhoto: photo.name, in: folder).map { (name: photo.name, url: $0) }
                }
                for await batch in FolderContents.embeddedMetadata(of: photos) {
                    contents[folder]?.setMetadata(batch)
                    if shown == selection { browse.keep(only: visiblePhotos) }
                }
                if Task.isCancelled { return }
            }
        }
    }

    var isEditing: Bool { browse.mode == .editing }

    /// What other apps recorded in XMP for the selected photo; `nil` until it has been read.
    var selectedPhotoMetadata: PhotoMetadata? {
        guard let photo = browse.selectedPhoto else { return nil }
        return contents[photo.folder]?.photos.first { $0.name == photo.name }?.metadata
    }

    /// Sets the selected photo's stars. Not saved: Proof doesn't write XMP yet, so the change
    /// lasts until the folder is read again or Proof quits.
    func setRating(_ rating: Int) {
        changeSelectedMetadata { $0.rating = rating }
    }

    /// Sets the selected photo's flag. Not saved, like `setRating`.
    func setFlag(_ flag: PhotoMetadata.Flag) {
        changeSelectedMetadata { $0.flag = flag }
    }

    private func changeSelectedMetadata(_ change: (inout PhotoMetadata) -> Void) {
        guard let photo = browse.selectedPhoto,
              let index = contents[photo.folder]?.photos.firstIndex(where: { $0.name == photo.name })
        else { return }
        var metadata = contents[photo.folder]?.photos[index].metadata ?? .unrated
        change(&metadata)
        contents[photo.folder]?.photos[index].metadata = metadata
        changedPhotos.insert(photo)
    }

    /// The file of the selected photo.
    var selectedPhotoURL: URL? {
        guard let photo = browse.selectedPhoto else { return nil }
        return url(ofPhoto: photo.name, in: photo.folder)
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
                selection = fileAccess.reference(for: url).map(SidebarItem.folder)
            case .locate(let location):
                try fileAccess.relink(location.id, to: url)
                contents = contents.filter { $0.key.locationID != location.id }
                refreshLocations()
                if selection == .allPhotos { readAllPhotos() }
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
        if selection?.folder?.locationID == location.id { selection = nil }
        refreshLocations()
        if selection == .allPhotos { readAllPhotos() }
    }

    private func refreshLocations() {
        guard let fileAccess else { return }
        locations = fileAccess.locations
        // Resolving never mounts a volume, so this doesn't wait on a disconnected NAS.
        statuses = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, fileAccess.resolve($0.id)) })
    }
}
