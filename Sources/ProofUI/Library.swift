import CoreGraphics
import Foundation
import Observation
import ProofKit
import SwiftUI

/// What the sidebar can select: All Photos, the photos across folders that pass one filter, or
/// one folder.
public enum SidebarItem: Codable, Hashable {
    case allPhotos
    case filtered(PhotoFilter)
    case folder(FileReference)

    public var folder: FileReference? {
        if case .folder(let folder) = self { folder } else { nil }
    }

    /// The filter of a filter row.
    public var filter: PhotoFilter? {
        if case .filtered(let filter) = self { filter } else { nil }
    }

    /// All Photos and the filter rows show photos from every available location.
    public var isAcrossFolders: Bool { folder == nil }
}

/// One photo's edit while Proof runs. Kept for every photo opened in Edit until Proof quits, so
/// each photo has its own undo history.
public struct PhotoEdit {
    /// Why the current edit isn't on disk.
    public enum Unsaved {
        /// The folder, or a photo saved on its own, was saved before Proof could write and
        /// hasn't been granted again.
        case noAccess
        /// The sidecar couldn't be read, so it isn't written over.
        case unreadable
        case failed
    }

    /// What the canvas and controls show. Ahead of `history.recipe` while a change is being made.
    public var recipe: EditRecipe
    public var history: EditHistory
    /// The sidecar as last read or written; `nil` when there is none.
    public var sidecar: Sidecar?
    /// The edit the photo has with no sidecar: neutral, with the crop and perspective correction
    /// the camera saved in the file (see `CameraSettings`). Revert returns to it.
    public var cameraEdit = EditRecipe()
    /// ISO, focal length, aperture and shutter speed, shown under the histogram. Read once the
    /// photo is opened.
    public var captureSettings: CaptureSettings?
    public var unsaved: Unsaved?
    /// The color profiles the photo offers, with what the decoder gives under each. `nil` until
    /// they have been read from the photo.
    public var profiles: CameraProfiles?
    /// The camera's white balance under the edit's profile, which the white balance controls show
    /// for As Shot. `nil` until it has been read from the photo.
    public var asShot: WhiteBalance? { profiles?.defaults(for: recipe.profile)?.asShot }
    /// The camera's sharpening and noise reduction under the edit's profile, which the Detail
    /// sliders show where the edit has none. `nil` until it has been read from the photo.
    public var cameraDetail: CameraDetail? { profiles?.defaults(for: recipe.profile)?.detail }
    /// The lens and whether the file has a correction profile, which the Lens Corrections card
    /// shows. `nil` until it has been read from the photo.
    public var cameraLens: CameraLens?
    /// The photo's size in pixels as the camera oriented it, under the edit's profile, which the
    /// crop tool lays out by. `nil` until it has been read from the photo.
    public var size: CGSize? { profiles?.defaults(for: recipe.profile)?.orientedSize }
}

/// The saved folders, what has been read of them, which folder, filter and photo are chosen, and
/// whether that photo is being edited. Shared by the sidebar, the grid, the toolbar and the menus.
@Observable @MainActor
public final class Library {
    /// Why the folder picker is open.
    public enum FolderRequest {
        case add
        case locate(SavedLocation)
        /// A folder saved with a read-only grant, chosen again so Proof can write sidecars in it.
        case grantWrite(SavedLocation)
    }

    public private(set) var locations: [SavedLocation] = []
    public private(set) var statuses: [UUID: LocationStatus] = [:]
    /// Folders read so far. A folder that couldn't be read is stored empty.
    public private(set) var contents: [FileReference: FolderContents] = [:]
    public var selection: SidebarItem? {
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
    /// While All Photos or a filter row is selected, whether folders under the saved locations are
    /// still being read.
    public private(set) var isReadingAllPhotos = false
    /// The toolbar filter, which narrows the selected folder, All Photos or filter row. A filter
    /// row's own criteria apply first, and this narrows them further (#182).
    /// The filmstrip's filter menu changes it too, so the two stay the same (#160).
    public var filter = FilterCriteria.none {
        didSet {
            // In Edit the photo shown stays until the person moves on, even if it doesn't match.
            changedPhotos = isEditing ? Set(browse.selectedPhoto.map { [$0] } ?? []) : []
            browse.keep(only: visiblePhotos)
        }
    }
    public var browse = BrowseState() {
        didSet {
            guard browse.selectedPhoto != oldValue.selectedPhoto || browse.mode != oldValue.mode else { return }
            // Moving to another photo in Edit lets the photos that stopped matching leave the filmstrip.
            if isEditing, oldValue.mode == .editing, !changedPhotos.isEmpty {
                changedPhotos = changedPhotos.filter { $0 == browse.selectedPhoto }
                browse.keep(only: visiblePhotos)
            }
            // Leaving the photo any way but Done or Cancel keeps the crop.
            if isCropping, let previous = oldValue.selectedPhoto { endCropping(of: previous) }
            isPickingWhiteBalance = false
            isDrawingGuides = false
            finishRemovingSpots()
            finishMasking()
            if let previous = oldValue.selectedPhoto { commitEdit(of: previous) }
            openSelectedEdit()
            closedGroups = AdjustmentGroup.initiallyOff(for: selectedEdit?.recipe)
            if isEditing, let photo = browse.selectedPhoto { downloadAround(photo) }
        }
    }

    /// The selected photo is in iCloud and not on this device yet, so Edit waits for its download.
    public var isSelectedPhotoInCloud: Bool {
        guard let photo = browse.selectedPhoto else { return false }
        return contents[photo.folder]?.photos.first { $0.name == photo.name }?.isInCloud == true
    }

    /// Photos in iCloud being downloaded because they were opened.
    public private(set) var downloadingPhotos: Set<PhotoReference> = []

    /// Downloads the opened photo if it is in iCloud and not on this device, and the photos before
    /// and after it, so moving to them is quick. No other photo is downloaded (decision 0050).
    private func downloadAround(_ photo: PhotoReference) {
        downloadIfInCloud(photo, reportingFailure: true)
        let shown = shownPhotos.map(\.id)
        guard let index = shown.firstIndex(of: photo) else { return }
        for neighbor in [index - 1, index + 1] where shown.indices.contains(neighbor) {
            downloadIfInCloud(shown[neighbor], reportingFailure: false)
        }
    }

    /// Downloads a photo that is in iCloud and not on this device, then reads its folder again so
    /// its thumbnail and metadata show.
    private func downloadIfInCloud(_ photo: PhotoReference, reportingFailure: Bool) {
        guard !downloadingPhotos.contains(photo),
              contents[photo.folder]?.photos.first(where: { $0.name == photo.name })?.isInCloud == true,
              let url = url(ofPhoto: photo.name, in: photo.folder) else { return }
        downloadingPhotos.insert(photo)
        Task {
            let downloaded = await CloudDownload.download(url)
            downloadingPhotos.remove(photo)
            if downloaded {
                refresh(photo.folder)
            } else if reportingFailure {
                errorMessage = "“\(photo.name)” couldn't be downloaded from iCloud."
            }
        }
    }
    /// The edits of photos opened in Edit since Proof started.
    public private(set) var edits: [PhotoReference: PhotoEdit] = [:]
    /// Thumbnails of photos edited since Proof started, showing their current edit. The grid and
    /// the filmstrip show these over the thumbnails they loaded.
    public private(set) var editedThumbnails: [PhotoReference: CGImage] = [:]
    /// Cards switched off while at their defaults, so their controls stay closed. Switching one
    /// off changes nothing that renders, so it isn't saved; opening a photo sets these again.
    /// Cards whose switch changes the render are switched off in the edit (decision 0046).
    private var closedGroups: Set<AdjustmentGroup> = []

    public func isOn(_ group: AdjustmentGroup) -> Bool {
        !closedGroups.contains(group) && selectedEdit?.recipe.switchedOff.contains(group) != true
    }

    /// Switching a card off leaves its adjustments out of the edit's render, on the canvas, in
    /// thumbnails and in export, as one undo step that is saved like any other change.
    public func setOn(_ group: AdjustmentGroup, _ isOn: Bool) {
        showEdited()
        if isOn { closedGroups.remove(group) }
        guard let photo = browse.selectedPhoto, let recipe = edits[photo]?.recipe else { return }
        if isOn, !recipe.switchedOff.contains(group) { return }
        if !isOn, !recipe.rendersDifferently(without: group) {
            closedGroups.insert(group)
            return
        }
        commitTask?.cancel()
        commitEdit(of: photo)
        if isOn { edits[photo]!.recipe.switchedOff.remove(group) } else { edits[photo]!.recipe.switchedOff.insert(group) }
        commitEdit(of: photo)
    }
    /// A control is being dragged. The change becomes one undo step, and is saved, when it ends.
    public var isAdjusting = false {
        didSet {
            commitTask?.cancel()
            if !isAdjusting, let photo = browse.selectedPhoto { commitEdit(of: photo) }
        }
    }
    /// The Distortion slider or a Transform slider is being dragged, which shows a grid over the photo.
    public var isAdjustingGeometry = false
    public var isInspectorShown = true
    /// The History panel on the leading side in Edit (#56).
    public var isHistoryShown = false
    /// The filmstrip under the photo in Edit (#159), remembered across launches.
    public var isFilmstripShown = UserDefaults.standard.object(forKey: Library.filmstripKey) as? Bool ?? true {
        didSet { UserDefaults.standard.set(isFilmstripShown, forKey: Self.filmstripKey) }
    }
    private static let filmstripKey = "filmstripShown"
    /// The color around the photo in Edit (#42), remembered across photos and launches.
    public var canvasColor = CanvasColor(stored: UserDefaults.standard.data(forKey: Library.canvasColorKey)) {
        didSet { UserDefaults.standard.set(canvasColor.encoded, forKey: Self.canvasColorKey) }
    }
    private static let canvasColorKey = "canvasColor"
    /// The Info panel beside the grid in Browse (#151).
    public var isInfoShown = false
    /// iPad and iPhone: the photo whose Info sheet is open, from its touch-and-hold menu (#233).
    public var infoSheetPhoto: PhotoReference?
    /// iPad and iPhone: Select in the toolbar is on, so a tap adds or removes a photo instead of
    /// opening it. It starts and ends with nothing selected, as in Photos, except when it ends by
    /// opening a photo, which stays selected.
    public var isSelectingPhotos = false {
        didSet { if isSelectingPhotos != oldValue, !isEditing { browse.selectedPhoto = nil } }
    }
    /// The Info panel's width when last open, so the grid can lay out for the width it will have
    /// once the panel has slid in or out.
    public var infoPanelWidth: CGFloat = 320
    /// The Info card below the histogram in Edit, collapsed until opened.
    public var isInfoCardExpanded = false
    /// The inspector cards folded with their arrows, remembered across photos and launches.
    public var foldedCards = FoldedCards(Set(UserDefaults.standard.stringArray(forKey: Library.foldedCardsKey) ?? [])) {
        didSet { UserDefaults.standard.set(foldedCards.titles.sorted(), forKey: Self.foldedCardsKey) }
    }
    private static let foldedCardsKey = "foldedInspectorCards"
    /// How far the photo in Edit is zoomed and where; back to Fit for each photo and for the crop tool.
    public let zoom = CanvasZoom()
    /// The LUT library and its previews of the photo in Edit, for the Look section.
    public let looks = LookBrowser()
    public var isChoosingFolder = false
    /// Kept apart from `isChoosingFolder`, which SwiftUI clears before the picker's result arrives.
    public private(set) var folderRequest: FolderRequest = .add
    public var errorMessage: String?
    /// The histogram of the latest render shown on the canvas, and the photo it was measured from.
    private var histogram: (url: URL, value: Histogram)?

    /// The histogram of the selected photo. Nil until its first render has been measured, so
    /// another photo's histogram is never shown in its place.
    public var selectedHistogram: Histogram? {
        guard let histogram, histogram.url == selectedPhotoURL else { return nil }
        return histogram.value
    }

    public func showHistogram(_ histogram: Histogram, of url: URL) {
        self.histogram = (url, histogram)
    }

    private let fileAccess: FileAccess?
    /// Saved export destinations (decision 0032). `nil` if their file couldn't be read.
    public let exportDestinations: ExportDestinations?
    private var metadataTask: Task<Void, Never>?
    private var allPhotosTask: Task<Void, Never>?
    /// Watches the available saved folders on local disks.
    private var watcher: FolderWatcher?
    /// Available saved locations on network volumes, which are rescanned instead of watched.
    private var networkLocations: Set<UUID> = []
    /// Commits a change made without a drag, such as a double-click reset, once the controls are idle.
    private var commitTask: Task<Void, Never>?
    /// Saved locations Proof has asked once this session to grant again for writing.
    private var askedForWriteAccess: Set<UUID> = []
    /// Photos whose rating or flag was changed since the filter or folder last changed. They stay
    /// visible even if the filter no longer matches, so a photo doesn't vanish while it's rated. In
    /// Edit they stay only until another photo is shown.
    private var changedPhotos: Set<PhotoReference> = []
    /// Photos whose rating or flag couldn't be saved yet because their folder has a read-only grant.
    public private(set) var unsavedMetadata: Set<PhotoReference> = []
    /// The latest XMP write. Each waits for the one before, so quick changes land in order.
    private var metadataWrite: Task<Void, Never>?
    private static let selectionKey = "selectedFolder"

    private let platform: LibraryPlatform
    /// The touch drag the grid selects photos with (`LibraryPlatform.sidewaysDrag`).
    var sidewaysDrag: (@MainActor (AnyView, SidewaysDragActions) -> AnyView)? { platform.sidewaysDrag }

    public init(platform: LibraryPlatform) {
        self.platform = platform
        fileAccess = try? FileAccess(storeURL: URL.applicationSupportDirectory
            .appendingPathComponent("Proof/locations.json"))
        if fileAccess == nil { errorMessage = "Proof couldn't load its saved folders." }
        exportDestinations = fileAccess.flatMap {
            try? ExportDestinations(storeURL: URL.applicationSupportDirectory
                .appendingPathComponent("Proof/export-destinations.json"), fileAccess: $0)
        }
        refreshLocations()
        looks.openFolder = platform.openFolder
        observeSystem()
        looks.onChange = { [weak self] in self?.refreshEditedThumbnails() }
        // Before All Photos, the selection was saved as a folder reference.
        selection = UserDefaults.standard.data(forKey: Self.selectionKey).flatMap { data in
            (try? JSONDecoder().decode(SidebarItem.self, from: data))
                ?? (try? JSONDecoder().decode(FileReference.self, from: data)).map(SidebarItem.folder)
        }
    }

    public func status(of id: UUID) -> LocationStatus {
        statuses[id] ?? .missing
    }

    /// The selected folder's photos, or for All Photos every photo read so far under the available
    /// locations, in sidebar order.
    public var listedPhotos: [ListedPhoto] {
        switch selection {
        case .folder(let folder): ListedPhoto.photos(of: folder, in: contents)
        case .allPhotos, .filtered: allListedPhotos
        case nil: []
        }
    }

    private var allListedPhotos: [ListedPhoto] {
        availableRoots.flatMap { ListedPhoto.photos(under: $0, in: contents) }
    }

    /// The filter that applies: a filter row's narrowed by the toolbar's, or the toolbar's.
    public var activeFilter: FilterCriteria {
        selection?.filter.map { $0.criteria.narrowed(by: filter) } ?? filter
    }

    /// The listed photos that pass the filter.
    public var visiblePhotos: [ListedPhoto] {
        activeFilter.filter(listedPhotos, keeping: changedPhotos)
    }

    /// The stacks of `visiblePhotos`, such as a RAW and its JPEG (decision 0049).
    public var stackMarks: [PhotoReference: StackMark] { StackMark.marks(in: visiblePhotos) }

    /// The stacks opened since Proof started, by their first photo. Stacks start collapsed.
    public private(set) var openStacks: Set<PhotoReference> = []

    /// `visiblePhotos` without the photos hidden in collapsed stacks: what the grid and the
    /// filmstrip show, and what arrow keys and Select All move through.
    public var shownPhotos: [ListedPhoto] {
        StackMark.shown(visiblePhotos, marks: stackMarks, open: openStacks)
    }

    /// The photos after `photo` in its stack, in order, when `photo` is the first photo of a
    /// collapsed stack; otherwise none.
    public func hiddenStackPhotos(of photo: PhotoReference) -> [PhotoReference] {
        let marks = stackMarks
        guard case .first = marks[photo], !openStacks.contains(photo) else { return [] }
        let visible = visiblePhotos
        guard let index = visible.firstIndex(where: { $0.id == photo }) else { return [] }
        return visible[(index + 1)...].prefix { marks[$0.id] == .member }.map(\.id)
    }

    /// Whether `photo` is the first photo of a stack, and that stack is open.
    public func isStackOpen(_ photo: PhotoReference) -> Bool { openStacks.contains(photo) }

    /// Opens or collapses the stack `photo` is in. Collapsing it selects its first photo in place
    /// of any it hides.
    public func toggleStack(of photo: PhotoReference) {
        let visible = visiblePhotos, marks = stackMarks
        guard let first = StackMark.first(of: photo, in: visible, marks: marks) else { return }
        if openStacks.remove(first) == nil {
            openStacks.insert(first)
            return
        }
        let shown = StackMark.shown(visible, marks: marks, open: openStacks)
        if let selected = browse.selectedPhoto, !shown.contains(where: { $0.id == selected }) {
            browse.selectedPhoto = first
        }
        browse.keep(only: shown)
    }

    /// How many photos read so far under the available locations each filter row matches.
    public var filterCounts: [PhotoFilter: Int] {
        PhotoFilter.counts(of: allListedPhotos.lazy.map(\.photo))
    }

    /// Saved locations All Photos leaves out because their drive isn't connected or they can't be found.
    public var unavailableLocations: [SavedLocation] {
        locations.filter { !isAvailable($0) }
    }

    private var availableRoots: [FileReference] {
        locations.filter(isAvailable)
            .map { FileReference(locationID: $0.id, relativePath: []) }
    }

    private func isAvailable(_ location: SavedLocation) -> Bool {
        isAvailable(location.id)
    }

    private func isAvailable(_ id: UUID) -> Bool {
        if case .available = status(of: id) { true } else { false }
    }

    /// A folder's name as the sidebar shows it: its own name, or the saved location's.
    public func name(of folder: FileReference) -> String {
        folder.relativePath.last ?? locations.first { $0.id == folder.locationID }?.name ?? ""
    }

    /// Where a folder sits under its saved location, as in "NAS › Albums › Coast".
    public func path(of folder: FileReference) -> String {
        let location = locations.first { $0.id == folder.locationID }?.name
        return ([location].compactMap { $0 } + folder.relativePath).joined(separator: " › ")
    }

    /// Reads a folder off the main thread. Already-read folders are read again only when `force` is
    /// set. Where Proof can write, sidecars left behind by a renamed photo are renamed to follow it
    /// first, and edits whose sidecar changed on disk are reloaded after (decision 0007).
    public func load(_ folder: FileReference, force: Bool = false) async {
        guard force || contents[folder] == nil else { return }
        guard let fileAccess, let url = fileAccess.url(for: folder) else { return }
        // Asking for access isn't worth it for relinking, so folders that can't be written are skipped.
        let canRelink = fileAccess.canWrite(to: url)
        let read = await Task.detached {
            if canRelink { _ = try? Sidecar.relink(in: url) }
            return try? FolderContents.read(at: url)
        }.value
        contents[folder] = (read ?? FolderContents(subfolders: [], photos: [])).keepingMetadata(from: contents[folder])
        if .folder(folder) == selection {
            browse.keep(only: visiblePhotos)
            readEmbeddedMetadata()
        }
        if force { await reloadChangedEdits(in: folder) }
    }

    /// Shows the edit now on disk for each photo in `folder` whose sidecar changed since Proof last
    /// read or wrote it, as one undo step. Proof's own writes match what it last wrote, so they
    /// change nothing. A photo with a change in progress, or one Proof couldn't save, keeps its
    /// edit: the most recent write wins, and that one hasn't been written yet.
    private func reloadChangedEdits(in folder: FileReference) async {
        for photo in edits.keys where photo.folder == folder {
            guard let url = url(ofPhoto: photo.name, in: photo.folder) else { continue }
            let read = await Task.detached { Result { try Sidecar.read(for: url) } }.value
            guard case .success(let sidecar) = read, var edit = edits[photo], edit.unsaved == nil, edit.recipe == edit.history.recipe,
                  sidecar != edit.sidecar else { continue }
            let recipe = sidecar?.recipe ?? edit.cameraEdit
            edit.sidecar = sidecar
            edit.history.record(recipe, label: "Changed Elsewhere")
            edit.recipe = recipe
            edits[photo] = edit
            refreshThumbnail(of: photo, at: url)
        }
    }

    /// For All Photos and the filter rows, reads every folder under the available locations, one at
    /// a time and in sidebar order, so the grid fills in folder by folder. Folders the sidebar
    /// already read are not read again. Reading stops when another item is selected.
    private func readAllPhotos() {
        allPhotosTask?.cancel()
        isReadingAllPhotos = false
        guard selection?.isAcrossFolders == true else { return }
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
        // Photos in iCloud would be downloaded to be read, so they wait until they are opened.
        let missing = Dictionary(grouping: listedPhotos.filter { $0.photo.metadata == nil && !$0.photo.isInCloud },
                                 by: \.folder)
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

    public var isEditing: Bool { browse.mode == .editing }

    /// What other apps recorded in XMP for the selected photo; `nil` until it has been read.
    public var selectedPhotoMetadata: PhotoMetadata? {
        guard let photo = browse.selectedPhoto else { return nil }
        return contents[photo.folder]?.photos.first { $0.name == photo.name }?.metadata
    }

    /// Sets the stars of `photos`, every selected photo by default, and saves them to their XMP sidecars.
    public func setRating(_ rating: Int, of photos: [PhotoReference]? = nil) {
        changeMetadata(of: photos ?? Array(browse.selectedPhotos)) { $0.rating = rating }
    }

    /// Sets the flag of `photos`, every selected photo by default, and saves it to their XMP sidecars.
    public func setFlag(_ flag: PhotoMetadata.Flag, of photos: [PhotoReference]? = nil) {
        changeMetadata(of: photos ?? Array(browse.selectedPhotos)) { $0.flag = flag }
    }

    /// The rating all `photos` share, or `nil` when they differ.
    public func commonRating(of photos: [PhotoReference]) -> Int? {
        let ratings = Set(photos.map { metadata(of: $0)?.rating ?? 0 })
        return ratings.count == 1 ? ratings.first : nil
    }

    /// The flag all `photos` share, or `nil` when they differ.
    public func commonFlag(of photos: [PhotoReference]) -> PhotoMetadata.Flag? {
        let flags = Set(photos.map { metadata(of: $0)?.flag ?? .unflagged })
        return flags.count == 1 ? flags.first : nil
    }

    private func metadata(of photo: PhotoReference) -> PhotoMetadata? {
        contents[photo.folder]?.photos.first { $0.name == photo.name }?.metadata
    }

    private func changeMetadata(of photos: [PhotoReference], _ change: (inout PhotoMetadata) -> Void) {
        for photo in photos {
            guard let index = contents[photo.folder]?.photos.firstIndex(where: { $0.name == photo.name }) else { continue }
            var metadata = contents[photo.folder]?.photos[index].metadata ?? .unrated
            change(&metadata)
            contents[photo.folder]?.photos[index].metadata = metadata
            changedPhotos.insert(photo)
            saveMetadata(of: photo)
        }
    }

    /// Writes the photo's rating and flag to its XMP sidecar off the main thread (decision 0022).
    /// Without write access the change stays in memory, and is saved once the folder is granted.
    private func saveMetadata(of photo: PhotoReference) {
        guard let url = url(ofPhoto: photo.name, in: photo.folder),
              let metadata = contents[photo.folder]?.photos.first(where: { $0.name == photo.name })?.metadata
        else { return }
        guard ensureCanWrite(nextTo: url) else {
            unsavedMetadata.insert(photo)
            return
        }
        unsavedMetadata.remove(photo)
        let previous = metadataWrite
        metadataWrite = Task {
            await previous?.value
            let result = await Task.detached { try XMPSidecar.save(metadata, for: url) }.result
            if case .failure(let error) = result {
                errorMessage = "The rating and flag of “\(photo.name)” couldn't be saved. (\(error.localizedDescription))"
            }
        }
    }

    /// Whether the photo's info is in view: the panel in Browse, the open card in Edit.
    public var isShowingInfo: Bool {
        isEditing ? isInspectorShown && isInfoCardExpanded : isInfoShown
    }

    /// Shows or hides the photo's info, for ⌘I. In Edit it opens the inspector if it is hidden.
    public func toggleInfo() {
        if isEditing {
            let show = !isShowingInfo
            isInfoCardExpanded = show
            if show { isInspectorShown = true }
        } else {
            isInfoShown.toggle()
        }
    }

    /// The photo the Info panel describes: the only selected one. With several selected it shows none.
    public var infoPhoto: PhotoReference? {
        browse.selectedPhotos.count == 1 ? browse.selectedPhotos.first : nil
    }

    /// Saves a photo's title, caption, keywords, creator, copyright and location to its XMP
    /// sidecar, after any rating or flag still being written to it. Returns whether it was saved.
    public func saveDescription(_ description: PhotoDescription, of photo: PhotoReference) async -> Bool {
        guard let url = url(ofPhoto: photo.name, in: photo.folder) else { return false }
        guard ensureCanWrite(nextTo: url) else {
            errorMessage = "The description of “\(photo.name)” couldn't be saved, because Proof can't write to its folder yet."
            return false
        }
        let metadata = metadata(of: photo) ?? .unrated
        let previous = metadataWrite
        let write = Task {
            await previous?.value
            let result = await Task.detached { try XMPSidecar.save(description, keeping: metadata, for: url) }.result
            if case .failure(let error) = result {
                errorMessage = "The description of “\(photo.name)” couldn't be saved. (\(error.localizedDescription))"
                return false
            }
            return true
        }
        metadataWrite = Task { _ = await write.value }
        return await write.value
    }

    // MARK: Edits

    /// The edit of the photo open in Edit.
    public var selectedEdit: PhotoEdit? {
        browse.selectedPhoto.flatMap { edits[$0] }
    }

    /// Changes the selected photo's edit. Outside a drag, the change is committed once the
    /// controls are idle, so a burst of key presses is one undo step.
    /// `label` names the step in the History panel, for a change whose sliders don't say what
    /// made it, such as Auto Tone. Without it the step says what changed.
    public func changeEdit(label: String? = nil, _ change: (inout EditRecipe) -> Void) {
        guard let photo = browse.selectedPhoto, edits[photo] != nil else { return }
        showEdited()
        change(&edits[photo]!.recipe)
        // A later change before the step is made gets the step named by what changed.
        pendingStepLabel = label
        commitTask?.cancel()
        guard !isAdjusting else { return }
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commitEdit(of: photo)
        }
    }

    /// The name `changeEdit` was given for the step it is about to make.
    @ObservationIgnored private var pendingStepLabel: String?

    /// Photo › Next Look and Previous Look can step through the shown folder's looks.
    public var canStepLook: Bool {
        isEditing && selectedEdit != nil && !looks.shownNames.isEmpty
    }

    /// Chooses the look `offset` places from the current one in the folder the Looks section
    /// shows, keeping its strength. Without a look, starts at the first or last.
    public func stepLook(by offset: Int) {
        guard canStepLook, let next = looks.look(steppingBy: offset, from: selectedEdit?.recipe.look?.lut) else { return }
        setOn(.look, true)
        changeEdit { recipe in
            recipe.look = Look(lut: next, strength: recipe.look?.strength ?? 1)
        }
    }

    public var canUndoEdit: Bool {
        guard let edit = selectedEdit else { return false }
        return edit.history.canUndo || edit.recipe != edit.history.recipe
    }

    public var canRedoEdit: Bool {
        selectedEdit?.history.canRedo == true
    }

    public func undoEdit() {
        stepEdit { $0.undo() }
    }

    public func redoEdit() {
        stepEdit { $0.redo() }
    }

    /// Clicking a step in the History panel: the photo as it was then. Undo and Redo move on
    /// from there, and a new change drops the steps after it.
    public func goToHistoryStep(_ index: Int) {
        stepEdit { $0.go(to: index) }
    }

    private func stepEdit(_ step: (inout EditHistory) -> EditRecipe?) {
        guard let photo = browse.selectedPhoto else { return }
        commitEdit(of: photo)
        guard var edit = edits[photo], let recipe = step(&edit.history) else { return }
        showEdited()
        edit.recipe = recipe
        edits[photo] = edit
        save(photo)
    }

    // MARK: Copy and paste settings

    /// What Edit › Copy last took, kept until Proof quits.
    public private(set) var copiedSettings: CopiedSettings?
    /// The Copy Settings sheet is open.
    public var isChoosingSettingsToCopy = false

    /// The selected photos in the order shown, for the menu bar's actions on the selection.
    public var selectedPhotosInOrder: [PhotoReference] {
        browse.selected(in: visiblePhotos)
    }

    /// The photos a right-click on `photo` acts on: the whole selection when the photo is in it,
    /// as in Finder, and otherwise only that photo.
    public func menuTargets(for photo: PhotoReference) -> [PhotoReference] {
        browse.selectedPhotos.contains(photo) ? selectedPhotosInOrder : [photo]
    }

    // MARK: Export

    public let exports = ExportQueue()
    /// The photos the export sheet is open for; empty while it is closed.
    public var photosToExport: [PhotoReference] = []

    /// One export at a time: its progress sheet stays open until it ends.
    public var canExport: Bool { !isCropping && !exports.isVisible && browse.selectedPhotos.contains(where: \.isEditable) }

    /// File › Export…: opens the export sheet for `photos`, every selected photo by default.
    /// JPEG and HEIC photos are left out until #239.
    public func requestExport(of photos: [PhotoReference]? = nil) {
        guard !isCropping, !exports.isVisible else { return }
        photosToExport = (photos ?? selectedPhotosInOrder).filter(\.isEditable)
    }

    /// Queues `photos` with the edits Proof has for them now; photos without one in memory are
    /// exported with their sidecar's.
    public func export(_ photos: [PhotoReference], settings: ExportSettings, to folder: URL) {
        exports.start(exportItems(photos), settings: settings, folder: folder)
        // The export sheet, if it is open, shows the export's progress instead.
        photosToExport = []
    }

    /// iPad and iPhone: queues `photos` for the share sheet, Save to Files or Photos.
    public func export(_ photos: [PhotoReference], settings: ExportSettings, delivery: ExportQueue.Delivery) {
        exports.start(exportItems(photos), settings: settings, delivery: delivery)
        photosToExport = []
    }

    /// The touch-and-hold menu's Export To on iPad and iPhone: exports `photos` right away with
    /// the last export's settings.
    public func export(_ photos: [PhotoReference]? = nil, delivery: ExportQueue.Delivery) {
        guard !isCropping, !exports.isVisible else { return }
        let photos = (photos ?? selectedPhotosInOrder).filter(\.isEditable)
        guard !photos.isEmpty else { return }
        export(photos, settings: .remembered(), delivery: delivery)
    }

    /// The photos with the edits Proof has for them now, saved first.
    private func exportItems(_ photos: [PhotoReference]) -> [ExportQueue.Item] {
        commitTask?.cancel()
        for photo in photos where edits[photo] != nil { commitEdit(of: photo) }
        return photos.compactMap { photo in
            url(ofPhoto: photo.name, in: photo.folder).map {
                ExportQueue.Item(url: $0, recipe: edits[photo]?.recipe, rating: metadata(of: photo)?.rating ?? 0)
            }
        }
    }

    /// File › Export To: exports `photos`, the selected photos by default, to a saved destination
    /// with its settings. When its folder can't be found, the export sheet opens on it instead, to
    /// show why and let the person choose the folder again.
    public func export(_ photos: [PhotoReference]? = nil, to destinationID: UUID) {
        guard !isCropping, !exports.isVisible, let destination = exportDestinations?.destination(destinationID) else { return }
        let photos = (photos ?? selectedPhotosInOrder).filter(\.isEditable)
        guard !photos.isEmpty else { return }
        UserDefaults.standard.set(destinationID.uuidString, forKey: ExportQueue.destinationKey)
        guard let folder = exportDestinations?.folder(of: destinationID) else {
            photosToExport = photos
            return
        }
        export(photos, settings: destination.settings, to: folder)
    }

    /// Copies from the photo Edit shows, in Browse too, or from a right-clicked photo.
    public var canCopySettings: Bool {
        !isCropping && browse.selectedPhoto?.isEditable == true && (!isEditing || selectedEdit != nil)
    }

    public var canPasteSettings: Bool {
        canCopySettings && copiedSettings != nil
    }

    /// The photo the Copy Settings sheet copies from.
    private var copySource: PhotoReference?

    /// Edit › Copy Settings…: opens the sheet for `photo`, the photo Edit shows by default, after
    /// reading its edit if it hasn't been opened.
    public func chooseSettingsToCopy(from photo: PhotoReference? = nil) {
        guard !isCropping, let photo = photo ?? browse.selectedPhoto, photo.isEditable, loadEdit(of: photo) else { return }
        copySource = photo
        isChoosingSettingsToCopy = true
    }

    /// Copies `items` of the edit as the canvas shows it.
    public func copySettings(_ items: Set<SettingsItem>) {
        guard let photo = copySource ?? browse.selectedPhoto, let edit = edits[photo] else { return }
        copiedSettings = CopiedSettings(from: edit.recipe, items: items)
    }

    /// Edit › Paste: replaces the copied items of the edit of `photos`, every selected photo by
    /// default, as one undo step in each photo's own history, and saves them. When the photo in
    /// Edit is among them, it turns on the switches of the cards it changed.
    public func pasteSettings(to photos: [PhotoReference]? = nil) {
        guard !isCropping, let copied = copiedSettings else { return }
        let photos = photos ?? selectedPhotosInOrder
        commitTask?.cancel()
        showEdited()
        for photo in photos where photo.isEditable && loadEdit(of: photo) {
            commitEdit(of: photo)
            edits[photo]!.recipe = edits[photo]!.recipe.pasting(copied)
            commitEdit(of: photo, label: "Paste Settings")
        }
        if isEditing, let shown = browse.selectedPhoto, photos.contains(shown), let recipe = selectedEdit?.recipe {
            let pasted = Set(copied.items.compactMap(\.group))
            closedGroups.subtract(pasted.subtracting(AdjustmentGroup.initiallyOff(for: recipe)))
        }
    }

    /// Those of `photos`, every selected photo by default, that have an edit to revert, whatever
    /// their undo history. Photos not opened since Proof started count when they have a sidecar.
    public func photosToRevert(among photos: [PhotoReference]? = nil) -> [PhotoReference] {
        guard !isCropping else { return [] }
        return (photos ?? selectedPhotosInOrder).filter { photo in
            if let edit = edits[photo] { return !edit.recipe.isAsShot(edit.cameraEdit) || edit.sidecar != nil }
            return contents[photo.folder]?.photos.first { $0.name == photo.name }?.isEdited == true
        }
    }

    /// The photos the revert confirmation is asking about.
    public private(set) var photosPendingRevert: [PhotoReference] = []
    /// Revert to Original asks first when it would revert more than one photo.
    public var isConfirmingRevert = false {
        didSet { if !isConfirmingRevert { photosPendingRevert = [] } }
    }

    /// Photo › Revert to Original, or the right-click menu's: reverts at once for one photo, and
    /// asks first for several.
    public func requestRevert(of photos: [PhotoReference]? = nil) {
        let photos = photosToRevert(among: photos)
        if photos.count > 1 {
            photosPendingRevert = photos
            isConfirmingRevert = true
        } else {
            revertEdit(of: photos)
        }
    }

    /// The confirmation's Revert button.
    public func revertPendingPhotos() {
        revertEdit(of: photosPendingRevert)
    }

    /// Returns the edit of each photo to the one it opens with, as one undo step in its own
    /// history, and deletes its sidecar (decision 0007). Undo writes the edit back as a new sidecar.
    private func revertEdit(of photos: [PhotoReference]) {
        commitTask?.cancel()
        showEdited()
        for photo in photos where loadEdit(of: photo) {
            commitEdit(of: photo)
            guard var edit = edits[photo] else { continue }
            edit.history.record(edit.cameraEdit, label: "Revert")
            edit.recipe = edit.cameraEdit
            edits[photo] = edit
            save(photo, reverting: true)
        }
    }

    /// Photo › Show Original (backslash): the photo without its edit, to compare. Any change to
    /// the edit, and the crop tool and eyedropper, show the edited photo again, so a change is
    /// never made out of sight.
    public func toggleOriginal() {
        guard isEditing, !isCropping, !isPickingWhiteBalance, !isRemovingSpots, !isMasking, selectedEdit != nil else { return }
        browse.toggleOriginal()
    }

    private func showEdited() {
        if browse.isShowingOriginal { browse.showEdited() }
    }

    /// Reads the photo's sidecar, and the settings its camera saved in the file, the first time it
    /// is opened in Edit, or copied from, pasted to or reverted in Browse. Later the edit and its undo history are kept in memory. Returns
    /// whether the photo has an edit in `edits`; a photo whose file can't be found has none.
    @discardableResult private func loadEdit(of photo: PhotoReference) -> Bool {
        if edits[photo] != nil { return true }
        guard let url = url(ofPhoto: photo.name, in: photo.folder) else { return false }
        do {
            let sidecar = try Sidecar.read(for: url)
            let cameraEdit = EditRecipe(asShot: CameraSettings(contentsOf: url))
            let recipe = sidecar?.recipe ?? cameraEdit
            edits[photo] = PhotoEdit(recipe: recipe, history: EditHistory(recipe, original: cameraEdit), sidecar: sidecar, cameraEdit: cameraEdit)
        } catch {
            edits[photo] = PhotoEdit(recipe: EditRecipe(), history: EditHistory(EditRecipe()), unsaved: .unreadable)
        }
        return true
    }

    /// A click on a thumbnail in the grid or the filmstrip: ⌘ adds or removes the photo, ⇧ selects
    /// a range, and a plain click selects only that photo.
    public func click(_ photo: PhotoReference, in photos: [ListedPhoto]) {
        let modifiers = platform.clickModifiers()
        if modifiers.contains(.command) {
            browse.toggle(photo, in: photos)
        } else if modifiers.contains(.shift) {
            browse.extend(to: photo, in: photos)
        } else {
            browse.selectedPhoto = photo
        }
    }

    /// ⌘A selects the photos shown in the grid or the filmstrip.
    public var canSelectPhotos: Bool {
        selection != nil && !isCropping && !visiblePhotos.isEmpty
    }

    /// Edit › Deselect All: in Browse, deselects every photo; in Edit, all but the photo shown.
    public func deselectAll() {
        if isEditing { browse.selectOnlyCurrent() } else { browse.selectedPhoto = nil }
    }

    /// Photos whose camera details have been read, which happens the first time Edit shows them.
    private var openedPhotos: Set<PhotoReference> = []

    /// Opens the photo Edit shows: reads its edit, and what the camera recorded, the first time.
    private func openSelectedEdit() {
        guard isEditing, let photo = browse.selectedPhoto, photo.isEditable, let url = selectedPhotoURL,
              !openedPhotos.contains(photo), loadEdit(of: photo) else { return }
        openedPhotos.insert(photo)
        // Off the main thread: it opens the RAW file, which can be slow on a network volume.
        Task {
            let (profiles, cameraLens, settings) = await Task.detached {
                (CameraProfiles.of(url), CameraLens.of(url), CaptureSettings.read(from: url))
            }.value
            edits[photo]?.profiles = profiles
            edits[photo]?.cameraLens = cameraLens
            edits[photo]?.captureSettings = settings
        }
    }

    // MARK: Spot Removal

    /// The Spot Removal tool is open: a click on the photo covers a spot, such as sensor dust.
    public private(set) var isRemovingSpots = false
    /// The spot the tool's controls change and Delete removes, by its place in the recipe's `spots`.
    public var selectedSpot: Int?
    /// The mode, size, feather and opacity the next spot gets: the last ones set, as in Lightroom.
    public private(set) var nextSpot = Spot(x: 0, y: 0, sourceX: 0, sourceY: 0)
    /// A source is being looked for, for the spot at this place in `spots`.
    public private(set) var findingSourceFor: Int?

    /// Opens or closes the Spot Removal tool.
    public func toggleSpotRemoval() {
        if isRemovingSpots {
            finishRemovingSpots()
            return
        }
        guard isEditing, !isCropping, selectedEdit != nil else { return }
        showEdited()
        isPickingWhiteBalance = false
        isDrawingGuides = false
        finishMasking()
        selectedSpot = nil
        isRemovingSpots = true
    }

    public func finishRemovingSpots() {
        isRemovingSpots = false
        selectedSpot = nil
    }

    /// The spot the controls show: the selected one, or the settings the next one gets.
    public var shownSpot: Spot {
        selectedSpot.flatMap { index in selectedEdit?.recipe.spots.indices.contains(index) == true
            ? selectedEdit?.recipe.spots[index] : nil } ?? nextSpot
    }

    /// Selects the spot at `index`, or none. The next spot takes its settings, but not a stroke's path.
    public func selectSpot(_ index: Int?) {
        selectedSpot = index
        if let index, let spots = selectedEdit?.recipe.spots, spots.indices.contains(index) {
            nextSpot = spots[index]
            nextSpot.points = []
        }
    }

    /// Changes the selected spot's settings, and the next spot's.
    public func changeSpot(_ change: (inout Spot) -> Void) {
        change(&nextSpot)
        nextSpot.points = []
        guard let index = selectedSpot else { return }
        changeEdit { recipe in
            guard recipe.spots.indices.contains(index) else { return }
            change(&recipe.spots[index])
        }
    }

    /// Covers a spot at `center`, in `Spot`'s coordinates, with the next spot's settings, and
    /// selects it. It shows at once, taking from beside it; the source Proof chooses replaces that
    /// when it has been found, in the same undo step.
    public func addSpot(at center: CGPoint, with renderer: RAWRenderer) async {
        guard let photo = browse.selectedPhoto, let url = selectedPhotoURL, let size = selectedEdit?.size else { return }
        var spot = nextSpot
        spot.center = center
        spot.source = Self.besideSpot(center: center, radius: spot.radius, photoSize: size)
        changeEdit { $0.spots.append(spot) }
        guard let index = selectedEdit?.recipe.spots.indices.last, let recipe = selectedEdit?.recipe else { return }
        selectedSpot = index
        // Held until the source is in, so adding a spot is one step.
        commitTask?.cancel()
        findingSourceFor = index
        defer { if findingSourceFor == index { findingSourceFor = nil } }
        var before = recipe
        before.spots.removeLast()
        let found: CGPoint?
        do {
            try await renderer.open(url)
            found = try await renderer.spotSource(center: center, radius: spot.radius, mode: spot.mode, recipe: before)
        } catch {
            found = nil
        }
        // The spot keeps the source beside it if it was moved, removed or replaced meanwhile.
        guard browse.selectedPhoto == photo, let found else {
            if browse.selectedPhoto == photo { changeEdit { _ in } }
            return
        }
        changeEdit { recipe in
            guard recipe.spots.indices.contains(index), recipe.spots[index] == spot else { return }
            recipe.spots[index].source = found
        }
    }

    /// Starts painting a stroke at `point`, in `Spot`'s coordinates, with the next spot's settings,
    /// and selects it. It takes from itself, changing nothing, until it is finished.
    public func beginStroke(at point: CGPoint) {
        guard selectedEdit != nil else { return }
        var spot = nextSpot
        spot.center = point
        spot.source = point
        spot.points = [point.x, point.y]
        // Painting, and choosing the source after it, is one undo step.
        isAdjusting = true
        changeEdit { $0.spots.append(spot) }
        selectedSpot = selectedEdit?.recipe.spots.indices.last
    }

    /// Adds `point` to the stroke being painted, the selected spot.
    public func extendStroke(to point: CGPoint) {
        guard let index = selectedSpot else { return }
        changeEdit { recipe in
            guard recipe.spots.indices.contains(index), !recipe.spots[index].points.isEmpty else { return }
            recipe.spots[index].append(point)
        }
    }

    /// Finishes the stroke being painted: it takes from beside it at once, then from the area
    /// Proof chooses when that has been found, in the same undo step. A stroke too short to be
    /// one becomes a circle.
    public func finishStroke(with renderer: RAWRenderer) async {
        defer { isAdjusting = false }
        guard let photo = browse.selectedPhoto, let url = selectedPhotoURL, let size = selectedEdit?.size,
              let index = selectedSpot, let recipe = selectedEdit?.recipe, recipe.spots.indices.contains(index)
        else { return }
        var spot = recipe.spots[index]
        if !spot.isStroke { spot.points = [] }
        spot.source = Self.besideStroke(spot, photoSize: size)
        changeEdit { $0.spots[index] = spot }
        findingSourceFor = index
        defer { if findingSourceFor == index { findingSourceFor = nil } }
        var before = recipe
        before.spots.remove(at: index)
        let found: CGPoint?
        do {
            try await renderer.open(url)
            found = try await renderer.spotSource(center: spot.center, radius: spot.radius, mode: spot.mode,
                                                  path: spot.path, recipe: before)
        } catch {
            found = nil
        }
        guard browse.selectedPhoto == photo, let found else { return }
        changeEdit { recipe in
            guard recipe.spots.indices.contains(index), recipe.spots[index] == spot else { return }
            recipe.spots[index].source = found
        }
    }

    /// Off to the side of the stroke, square to the line from its first point to its last, as
    /// far as Proof's own choice at its nearest; a circle as `besideSpot` places it.
    public static func besideStroke(_ spot: Spot, photoSize: CGSize) -> CGPoint {
        let path = spot.path
        guard spot.isStroke, let first = path.first, let last = path.last else {
            return besideSpot(center: spot.center, radius: spot.radius, photoSize: photoSize)
        }
        let width = max(photoSize.width, 1), height = max(photoSize.height, 1), long = max(width, height)
        // In pixels of the photo, so the turn is square on the photo.
        let dx = (last.x - first.x) * width, dy = (last.y - first.y) * height
        let length = hypot(dx, dy)
        let across = spot.radius * 2.4 * long
        let nx = length > 0 ? -dy / length : 0, ny = length > 0 ? dx / length : 1
        let side = CGPoint(x: spot.center.x + nx * across / width, y: spot.center.y + ny * across / height)
        // The other side when that one is off the photo.
        guard (0...1).contains(side.x), (0...1).contains(side.y) else {
            return CGPoint(x: spot.center.x - nx * across / width, y: spot.center.y - ny * across / height)
        }
        return side
    }

    /// The same distance away as Proof's own choice at its nearest, to the right or, near the
    /// photo's right edge, to the left.
    public static func besideSpot(center: CGPoint, radius: Double, photoSize: CGSize) -> CGPoint {
        let across = radius * 2.4 * max(photoSize.width, photoSize.height) / max(photoSize.width, 1)
        let x = center.x + across + radius <= 1 ? center.x + across : center.x - across
        return CGPoint(x: x, y: center.y)
    }

    /// Moves the spot at `index`, keeping its source where it was, or its source alone.
    public func moveSpot(at index: Int, to center: CGPoint? = nil, source: CGPoint? = nil) {
        changeEdit { recipe in
            guard recipe.spots.indices.contains(index) else { return }
            if let center { recipe.spots[index].center = center }
            if let source { recipe.spots[index].source = source }
        }
    }

    public func removeSpot(at index: Int) {
        selectedSpot = nil
        changeEdit { recipe in
            guard recipe.spots.indices.contains(index) else { return }
            recipe.spots.remove(at: index)
        }
    }

    public func clearSpots() {
        selectedSpot = nil
        changeEdit { $0.spots = [] }
    }

    // MARK: Masks

    /// The Masks tool is open: the inspector lists the photo's masks and the photo shows the
    /// selected one's handles.
    public private(set) var isMasking = false
    /// The mask the tool's controls change and Delete removes, by its place in the recipe's `layers`.
    public var selectedLayer: Int?
    /// Tints the selected mask red on the photo (O).
    public var showsMaskOverlay = false
    /// The size, feather and flow of the next brush stroke, as last set.
    public var nextStroke = BrushStroke()
    /// The brush takes away from the mask rather than adding to it. Option inverts it while held.
    public var isErasing = false
    /// Vision is looking for the subject, for a new Subject mask.
    public private(set) var isFindingSubject = false

    public var layers: [Layer] { selectedEdit?.recipe.layers ?? [] }

    public var shownLayer: Layer? {
        selectedLayer.flatMap { layers.indices.contains($0) ? layers[$0] : nil }
    }

    /// The layer the canvas tints red: the selected one while Show Overlay is on, and while its
    /// adjustments are all at 0, so a new mask can be seen as it is drawn. Moving one of its
    /// sliders turns Show Overlay off, so the change can be seen.
    public var overlaidLayer: Int? {
        guard isMasking, let index = selectedLayer, let layer = shownLayer else { return nil }
        return showsMaskOverlay || layer.adjustments.isNeutral ? index : nil
    }

    /// Opens or closes the Masks tool.
    public func toggleMasks() {
        if isMasking {
            finishMasking()
            return
        }
        guard isEditing, !isCropping, selectedEdit != nil else { return }
        showEdited()
        isPickingWhiteBalance = false
        isDrawingGuides = false
        finishRemovingSpots()
        selectedLayer = layers.indices.last
        isMasking = true
    }

    public func finishMasking() {
        isMasking = false
        selectedLayer = nil
    }

    /// Adds a new mask and selects it. A gradient appears at once where it is most often wanted,
    /// to move and shape on the photo: a linear one fading down from the top, over the sky, and
    /// a radial one in the middle. A brush mask is empty, to paint on. A subject mask is added
    /// once Vision has found the subject.
    public func addMask(_ kind: Mask.Kind, with renderer: RAWRenderer?) async {
        switch kind {
        case .linear:
            selectLayer(appendLayer(Mask(.linear(LinearMask(start: CGPoint(x: 0.5, y: 0), end: CGPoint(x: 0.5, y: 0.4))))))
        case .radial:
            let size = selectedEdit?.size ?? CGSize(width: 3, height: 2)
            let short = min(size.width, size.height) / max(size.width, size.height, 1)
            selectLayer(appendLayer(Mask(.radial(RadialMask(center: CGPoint(x: 0.5, y: 0.5),
                                                            radiusX: short * 0.4, radiusY: short * 0.3)))))
        case .brush:
            selectLayer(appendLayer(Mask(.brush(BrushMask()))))
        case .subject:
            await addSubjectMask(with: renderer)
        }
    }

    /// Adds `mask` as a new layer, named for its place, and returns its index.
    @discardableResult
    public func appendLayer(_ mask: Mask) -> Int? {
        let names = Set(layers.map(\.name))
        let number = ((layers.count + 1)...).first { !names.contains("Mask \($0)") }!
        changeEdit { $0.layers.append(Layer(name: "Mask \(number)", mask: mask)) }
        return layers.indices.last
    }

    private func addSubjectMask(with renderer: RAWRenderer?) async {
        guard let renderer, let photo = browse.selectedPhoto, let url = selectedPhotoURL,
              let recipe = selectedEdit?.recipe else { return }
        isFindingSubject = true
        defer { isFindingSubject = false }
        do {
            try await renderer.open(url)
            let found = try await renderer.subjectMask(recipe: recipe)
            guard browse.selectedPhoto == photo, isMasking else { return }
            guard let found else {
                errorMessage = "No subject was found in this photo."
                return
            }
            selectLayer(appendLayer(Mask(.subject(found))))
        } catch {
            if browse.selectedPhoto == photo { errorMessage = "The subject couldn't be found. (\(error))" }
        }
    }

    public func selectLayer(_ index: Int?) {
        selectedLayer = index
    }

    public func changeLayer(at index: Int, _ change: (inout Layer) -> Void) {
        changeEdit { recipe in
            guard recipe.layers.indices.contains(index) else { return }
            change(&recipe.layers[index])
        }
    }

    /// Changes the selected layer's adjustments.
    public func changeAdjustments(_ change: (inout LocalAdjustments) -> Void) {
        guard let index = selectedLayer else { return }
        showsMaskOverlay = false
        changeLayer(at: index) { change(&$0.adjustments) }
    }

    public func removeLayer(at index: Int) {
        changeEdit { recipe in
            guard recipe.layers.indices.contains(index) else { return }
            recipe.layers.remove(at: index)
        }
        selectedLayer = layers.isEmpty ? nil : min(index, layers.count - 1)
    }

    public func duplicateLayer(at index: Int) {
        guard layers.indices.contains(index) else { return }
        var copy = layers[index]
        copy.name += " Copy"
        changeEdit { $0.layers.insert(copy, at: index + 1) }
        selectedLayer = index + 1
    }

    public func clearMasks() {
        selectedLayer = nil
        changeEdit { $0.layers = [] }
    }

    /// Starts a brush stroke at `point` on the selected brush mask, with the next stroke's settings.
    public func startStroke(at point: CGPoint, erasing: Bool) {
        guard let index = selectedLayer, case .brush = shownLayer?.mask.shape else { return }
        var stroke = nextStroke
        stroke.points = []
        stroke.append(point)
        stroke.erases = erasing
        changeLayer(at: index) { layer in
            guard case var .brush(brush) = layer.mask.shape else { return }
            brush.strokes.append(stroke)
            layer.mask.shape = .brush(brush)
        }
    }

    /// Carries the stroke being painted on to `point`.
    public func continueStroke(to point: CGPoint) {
        guard let index = selectedLayer else { return }
        changeLayer(at: index) { layer in
            guard case var .brush(brush) = layer.mask.shape, !brush.strokes.isEmpty else { return }
            brush.strokes[brush.strokes.count - 1].append(point)
            layer.mask.shape = .brush(brush)
        }
    }

    // MARK: Crop

    /// The crop tool is open on the selected photo.
    public private(set) var isCropping = false
    /// The straighten slider is being dragged, which shows a finer grid over the photo.
    public var isStraightening = false
    /// The edit when the crop tool opened, which Cancel returns to.
    private var recipeBeforeCrop: EditRecipe?
    /// The rectangle as it was before straightening shrank it, so it grows back as the angle
    /// returns toward zero.
    private var unstraightenedFrame: CropFrame?
    /// Drags on the photo draw a line to level the photo along, instead of moving the rectangle.
    /// The line stays, with its ends draggable, until the ruler is turned off.
    public var isDrawingLevelLine = false {
        didSet { if !isDrawingLevelLine { keptLevelLine = nil } }
    }
    /// The last line drawn with the ruler, and the turn and flips it was drawn on.
    private var keptLevelLine: (line: LevelLine, turn: Crop)?
    /// Auto is looking for the horizon.
    public private(set) var isFindingHorizon = false
    /// Auto found no horizon, which the crop tool shows for a moment.
    public private(set) var foundNoHorizon = false
    /// Auto white balance or Auto Tone is measuring the photo.
    public private(set) var isAutoAdjusting = false
    /// The White Balance eyedropper is waiting for a click on something neutral in the photo.
    public var isPickingWhiteBalance = false

    /// The selected photo's crop. A photo without one starts locked to its own shape (Original).
    public var selectedCrop: Crop {
        selectedEdit?.recipe.crop ?? Crop.uncropped(photoSize: selectedEdit?.size)
    }

    /// The selected photo turned and flipped, in pixels: the space the crop rectangle is in.
    /// `nil` until the photo's size has been read.
    public var turnedPhotoSize: CGSize? {
        selectedEdit?.size.map { selectedCrop.turnedSize(of: $0) }
    }

    /// The crop rectangle of the selected photo, in the units of `turnedPhotoSize`.
    public var selectedCropFrame: CropFrame? {
        turnedPhotoSize.map { CropFrame(selectedCrop, imageSize: $0) }
    }

    public func startCropping() {
        guard isEditing, !isCropping, let photo = browse.selectedPhoto, let edit = edits[photo] else { return }
        commitTask?.cancel()
        commitEdit(of: photo)
        recipeBeforeCrop = edit.recipe
        showEdited()
        unstraightenedFrame = nil
        isPickingWhiteBalance = false
        isDrawingGuides = false
        finishRemovingSpots()
        finishMasking()
        isCropping = true
    }

    /// Done: keeps the crop and closes the tool.
    public func finishCropping() {
        guard isCropping, let photo = browse.selectedPhoto else { return }
        endCropping(of: photo)
        commitEdit(of: photo)
    }

    /// Cancel: returns to the edit from when the tool opened, as one undo step.
    public func cancelCropping() {
        guard isCropping, let photo = browse.selectedPhoto else { return }
        commitTask?.cancel()
        if let recipeBeforeCrop { edits[photo]?.recipe = recipeBeforeCrop }
        endCropping(of: photo)
        commitEdit(of: photo)
    }

    /// Closes the tool. A crop that changes nothing is removed, so it doesn't keep the ratio alone.
    private func endCropping(of photo: PhotoReference) {
        if edits[photo]?.recipe.crop?.isIdentity == true { edits[photo]?.recipe.crop = nil }
        isCropping = false
        isStraightening = false
        isDrawingLevelLine = false
        foundNoHorizon = false
        recipeBeforeCrop = nil
        unstraightenedFrame = nil
    }

    /// Sets the rectangle from a drag on the photo. It becomes the size straightening starts from.
    public func setCropFrame(_ frame: CropFrame) {
        unstraightenedFrame = frame
        changeCrop { frame.applied(to: $0) }
    }

    /// Sets the straighten angle, shrinking the rectangle as needed to keep it on the photo.
    public func setStraighten(_ angle: Double) {
        guard let current = selectedCropFrame else { return }
        // The kept rectangle applies only while nothing else, such as undo, has changed the crop.
        var base = current
        if let kept = unstraightenedFrame, kept.imageSize == current.imageSize,
           kept.straightened(current.angle).isClose(to: current) {
            base = kept
        }
        unstraightenedFrame = base
        changeCrop { base.straightened(angle).applied(to: $0) }
    }

    /// The line drawn with the ruler, while the photo is still turned and flipped as it was drawn.
    public var levelLine: LevelLine? {
        guard let kept = keptLevelLine else { return nil }
        let crop = selectedCrop
        guard kept.turn.rotation == crop.rotation, kept.turn.flipHorizontal == crop.flipHorizontal,
              kept.turn.flipVertical == crop.flipVertical else { return nil }
        return kept.line
    }

    /// Removes the drawn line, keeping the angle it set.
    public func clearLevelLine() {
        keptLevelLine = nil
    }

    /// Keeps `line` on the photo and straightens so it becomes level or upright.
    public func level(along line: LevelLine) {
        keptLevelLine = (line, selectedCrop)
        guard let angle = line.straightenAngle else { return }
        setStraighten(angle)
    }

    /// Sets the selected photo's white balance to the one Auto estimates, labelled Auto.
    public func autoWhiteBalance(with renderer: RAWRenderer) async {
        await autoAdjust(with: renderer, what: "white balance") { renderer, recipe in
            let found = try await renderer.autoWhiteBalance(recipe: recipe)
            return { $0.basic.setAuto(found) }
        }
    }

    /// Opens or closes the White Balance eyedropper.
    public func toggleWhiteBalancePicker() {
        guard isEditing, !isCropping, selectedEdit?.asShot != nil else { return }
        showEdited()
        finishRemovingSpots()
        finishMasking()
        isPickingWhiteBalance.toggle()
    }

    /// Sets the white balance that makes `patch` of the selected photo neutral gray, as Custom,
    /// and closes the eyedropper, as Lightroom's closes after one click. A patch too dark to tell
    /// its color beeps and leaves the eyedropper open for another try.
    public func pickWhiteBalance(in patch: CGRect, with renderer: RAWRenderer) async {
        let photo = browse.selectedPhoto
        var isTooDark = false
        await autoAdjust(with: renderer, what: "white balance") { renderer, recipe in
            let found = try await renderer.whiteBalance(neutralIn: patch, recipe: recipe)
            isTooDark = found == nil
            return { recipe in
                guard let found else { return }
                recipe.basic.setTemperature(found.temperature)
                recipe.basic.setTint(found.tint)
            }
        }
        guard browse.selectedPhoto == photo else { return }
        if isTooDark {
            platform.beep()
        } else {
            setOn(.whiteBalance, true)
            isPickingWhiteBalance = false
        }
    }

    /// Sets the selected photo's six Tone sliders to the values Auto estimates.
    public func autoTone(with renderer: RAWRenderer) async {
        await autoAdjust(with: renderer, what: "tone", label: "Auto Tone") { renderer, recipe in
            let light = try await renderer.autoTone(recipe: recipe)
            return { light.apply(to: &$0.basic) }
        }
    }

    /// Remove Chromatic Aberration is measuring the selected photo. Its switch shows on meanwhile,
    /// with a spinner, so turning it on answers at once.
    public private(set) var isMeasuringChromaticAberration = false

    /// Turns Remove Chromatic Aberration on, measuring the selected photo's fringes, or off.
    public func setRemovesChromaticAberration(_ isOn: Bool, with renderer: RAWRenderer) async {
        guard isOn else {
            changeEdit { $0.lens.chromaticAberration = nil }
            return
        }
        guard !isAutoAdjusting else { return }
        isMeasuringChromaticAberration = true
        defer { isMeasuringChromaticAberration = false }
        await autoAdjust(with: renderer, what: "chromatic aberration") { renderer, recipe in
            let found = try await renderer.chromaticAberration(recipe: recipe)
            return { $0.lens.chromaticAberration = found }
        }
    }

    // MARK: Transform

    /// Upright is looking for lines in the selected photo.
    public private(set) var isFindingLines = false
    /// The mode Upright is looking for lines for, which the menu shows meanwhile.
    public private(set) var findingMode: UprightMode?
    /// Upright found no lines to go by, which the Transform card shows for a moment.
    public private(set) var foundNoLines = false
    /// Guided is open: a drag on the photo draws a line to make upright or level.
    public var isDrawingGuides = false {
        didSet { selectedGuide = nil }
    }
    /// The guide chosen last on the guide tool, by its place in the photo's guides, which Delete
    /// Guide removes.
    public var selectedGuide: Int?
    /// The lines found in a photo, kept while its lens corrections stay the same, so trying
    /// each Upright mode in turn doesn't look again.
    private var foundLines: (photo: PhotoReference, lens: LensCorrections, segments: [LineSegment], size: CGSize)?

    /// The most guides Guided keeps, as in Lightroom: two each way pin every slider it sets.
    public static let maximumGuides = 4

    /// Sets the Transform sliders as Upright `mode` chooses them, or returns them to none for
    /// `nil` (Off). Aspect, Scale and the offsets are kept. Guided opens the guide tool instead,
    /// keeping guides drawn before. Upright straightens the photo itself, so the crop's
    /// straighten angle goes back to zero, as Lightroom resets it.
    public func setUpright(_ mode: UprightMode?, with renderer: RAWRenderer) async {
        guard let photo = browse.selectedPhoto, let recipe = selectedEdit?.recipe else { return }
        setOn(.transform, true)
        switch mode {
        case nil:
            isDrawingGuides = false
            changeEdit { recipe in
                recipe.transform = recipe.transform.with(vertical: 0, horizontal: 0, rotate: 0)
                recipe.transform.upright = nil
                recipe.transform.guides = []
            }
        case .guided:
            finishRemovingSpots()
            finishMasking()
            isDrawingGuides = true
            let size = selectedEdit?.size
            changeEdit { recipe in
                recipe.transform.upright = .guided
                recipe.transform = Self.solveGuides(recipe.transform, size: size)
            }
        case let mode?:
            isDrawingGuides = false
            guard !isFindingLines, let url = selectedPhotoURL else { return }
            isFindingLines = true
            findingMode = mode
            defer { isFindingLines = false }
            if foundLines?.photo != photo || foundLines?.lens != recipe.lens {
                do {
                    try await renderer.open(url)
                    let lines = try await renderer.uprightSegments(recipe: recipe)
                    foundLines = (photo, recipe.lens, lines.segments, lines.size)
                } catch {
                    errorMessage = "Upright couldn't look for lines in this photo. (\(error))"
                    return
                }
            }
            // Another photo may have been chosen meanwhile.
            guard browse.selectedPhoto == photo, let found = foundLines, found.photo == photo else { return }
            // With no lines to go by, the mode is still the one chosen, so the menu shows it, but
            // it corrects nothing.
            let solved = Upright.solve(mode, segments: found.segments, size: found.size, from: recipe.transform)
            changeEdit { recipe in
                if let solved {
                    recipe.transform = solved
                    recipe.crop?.angle = 0
                } else {
                    recipe.transform = recipe.transform.with(vertical: 0, horizontal: 0, rotate: 0)
                    recipe.transform.upright = mode
                    recipe.transform.guides = []
                }
            }
            if solved == nil {
                foundNoLines = true
                try? await Task.sleep(for: .seconds(2))
                foundNoLines = false
            }
        }
    }

    /// Adds a guide, from 0 to 1 on each axis of the uncorrected photo, replacing the oldest once
    /// there are `maximumGuides`, and straightens to the guides.
    public func addGuide(_ guide: GuideLine) {
        let size = selectedEdit?.size
        selectedGuide = nil
        changeEdit { recipe in
            recipe.transform.guides = Array((recipe.transform.guides + [guide]).suffix(Self.maximumGuides))
            recipe.transform.upright = .guided
            recipe.transform = Self.solveGuides(recipe.transform, size: size)
            recipe.crop?.angle = 0
        }
    }

    /// Replaces the guide at `index`, moved by an end or as a whole, and straightens to the
    /// guides again.
    public func setGuide(at index: Int, to guide: GuideLine) {
        let size = selectedEdit?.size
        changeEdit { recipe in
            guard recipe.transform.guides.indices.contains(index) else { return }
            recipe.transform.guides[index] = guide
            recipe.transform = Self.solveGuides(recipe.transform, size: size)
        }
    }

    /// Removes the guide at `index` and straightens to the ones left.
    public func removeGuide(at index: Int) {
        let size = selectedEdit?.size
        selectedGuide = nil
        changeEdit { recipe in
            guard recipe.transform.guides.indices.contains(index) else { return }
            recipe.transform.guides.remove(at: index)
            recipe.transform = Self.solveGuides(recipe.transform, size: size)
        }
    }

    /// Removes the guides and the correction they made.
    public func clearGuides() {
        selectedGuide = nil
        changeEdit { recipe in
            recipe.transform.guides = []
            recipe.transform = recipe.transform.with(vertical: 0, horizontal: 0, rotate: 0)
        }
    }

    /// `transform` straightened to its guides, on a photo of `size`, or with no tilt or turn
    /// while it has none. Static, since it runs inside `changeEdit`, which holds the edits.
    private static func solveGuides(_ transform: PerspectiveTransform, size: CGSize?) -> PerspectiveTransform {
        guard let size,
              let solved = Upright.solve(.guided, segments: [], size: size, from: transform)
        else { return transform.with(vertical: 0, horizontal: 0, rotate: 0) }
        return solved
    }

    /// Measures the selected photo with `estimate` and applies the change it returns as one edit,
    /// unless another photo was chosen meanwhile. Takes about a second for white balance.
    private func autoAdjust(with renderer: RAWRenderer, what: String, label: String? = nil,
                            estimate: (RAWRenderer, EditRecipe) async throws -> (inout EditRecipe) -> Void) async {
        guard !isAutoAdjusting, let photo = browse.selectedPhoto, let url = selectedPhotoURL,
              let recipe = selectedEdit?.recipe else { return }
        isAutoAdjusting = true
        defer { isAutoAdjusting = false }
        let change: (inout EditRecipe) -> Void
        do {
            try await renderer.open(url)
            change = try await estimate(renderer, recipe)
        } catch {
            errorMessage = "Auto couldn't measure the \(what) of this photo. (\(error))"
            return
        }
        guard browse.selectedPhoto == photo else { return }
        changeEdit(label: label, change)
    }

    /// Straightens to the horizon Vision finds in the selected photo. When there is none, the
    /// angle stays as it was and `foundNoHorizon` is set for two seconds.
    public func autoStraighten(with renderer: RAWRenderer) async {
        guard isCropping, !isFindingHorizon, let photo = browse.selectedPhoto, let url = selectedPhotoURL,
              let recipe = selectedEdit?.recipe else { return }
        isFindingHorizon = true
        foundNoHorizon = false
        let correction: Double?
        do {
            try await renderer.open(url)
            // About the size of the photo on screen: enough for Vision, quick to render.
            let lut = await LUTLibrary.shared.lut(for: recipe.look)
            correction = try await renderer.horizonCorrection(fitting: CGSize(width: 1024, height: 1024), recipe: recipe,
                                                              lut: lut)
        } catch {
            isFindingHorizon = false
            errorMessage = "The horizon couldn't be found. (\(error))"
            return
        }
        isFindingHorizon = false
        // The photo or the tool may have changed while Vision looked.
        guard isCropping, browse.selectedPhoto == photo else { return }
        if let correction {
            setStraighten(correction)
        } else {
            foundNoHorizon = true
            try? await Task.sleep(for: .seconds(2))
            foundNoHorizon = false
        }
    }

    /// Locks the rectangle to `aspect`, or unlocks it for `nil`, taking the largest rectangle of
    /// that shape around the current center.
    public func setCropAspect(_ aspect: AspectRatio?) {
        guard let current = selectedCropFrame else { return }
        unstraightenedFrame = nil
        changeCrop { crop in
            var crop = crop
            crop.aspect = aspect
            return current.withAspect(aspect).applied(to: crop)
        }
    }

    /// Switches the rectangle between landscape and portrait. Freeform stays freeform.
    public func swapCropOrientation() {
        guard let current = selectedCropFrame else { return }
        let shape = selectedCrop.aspect ?? AspectRatio(current.size.width, current.size.height)
        unstraightenedFrame = nil
        changeCrop { crop in
            var crop = crop
            if crop.aspect != nil { crop.aspect = shape.swapped }
            return current.withAspect(shape.swapped).applied(to: crop)
        }
    }

    /// The selected photo's own shape, as the crop is turned: what Original locks to.
    public var originalAspect: AspectRatio? {
        turnedPhotoSize.map { AspectRatio($0.width, $0.height) }
    }

    public func rotate(clockwise: Bool) {
        keptLevelLine = nil
        unstraightenedFrame = nil
        changeCrop { var crop = $0; crop.rotate(clockwise: clockwise); return crop }
    }

    public func flipHorizontally() {
        keptLevelLine = nil
        unstraightenedFrame = nil
        changeCrop { var crop = $0; crop.flipHorizontally(); return crop }
    }

    public func flipVertically() {
        keptLevelLine = nil
        unstraightenedFrame = nil
        changeCrop { var crop = $0; crop.flipVertically(); return crop }
    }

    /// Removes the rectangle and straighten and locks the ratio to Original, keeping the turn and flips.
    public func resetCropRectangle() {
        unstraightenedFrame = nil
        let original = originalAspect
        changeCrop { Crop(rotation: $0.rotation, flipHorizontal: $0.flipHorizontal, flipVertical: $0.flipVertical,
                          aspect: original) }
    }

    /// Whether the crop differs from where the crop tool starts: the whole photo, locked to Original.
    public var canResetCropRectangle: Bool {
        let crop = selectedCrop
        guard let original = originalAspect, let aspect = crop.aspect else { return crop.hasRectangle || crop.aspect == nil }
        return crop.hasRectangle || !aspect.matches(original)
    }

    /// Undoes the turn and flips, keeping the rectangle on the same part of the photo.
    public func resetCropTurn() {
        keptLevelLine = nil
        unstraightenedFrame = nil
        changeCrop { crop in
            var crop = crop
            if crop.flipHorizontal { crop.flipHorizontally() }
            if crop.flipVertical { crop.flipVertically() }
            while crop.rotation != 0 { crop.rotate(clockwise: false) }
            return crop
        }
    }

    /// Outside the crop tool, such as a menu's rotate, a crop that ends up changing nothing is removed.
    private func changeCrop(_ change: (Crop) -> Crop) {
        // Read before `changeEdit`: reading the edit while it is being changed stops the app.
        let uncropped = Crop.uncropped(photoSize: selectedEdit?.size)
        changeEdit { recipe in
            let crop = change(recipe.crop ?? uncropped)
            recipe.crop = !isCropping && crop.isIdentity ? nil : crop
        }
    }

    /// Makes the photo's current change one undo step and saves it. `label` names the step in
    /// the History panel; without it the step says what changed.
    private func commitEdit(of photo: PhotoReference, label: String? = nil) {
        defer { pendingStepLabel = nil }
        guard var edit = edits[photo], edit.history.record(edit.recipe, label: label ?? pendingStepLabel) else { return }
        edits[photo] = edit
        save(photo)
    }

    /// Writes the photo's edit to its sidecar, or deletes the sidecar when the edit is neutral
    /// (decision 0007). `reverting` deletes the sidecar whatever it holds.
    /// When Proof can't write there, the edit stays in memory and `unsaved` says why.
    private func save(_ photo: PhotoReference, reverting: Bool = false) {
        guard var edit = edits[photo], let url = url(ofPhoto: photo.name, in: photo.folder) else { return }
        // Runs last: the thumbnail follows the edit whether or not it could be saved.
        defer { refreshThumbnail(of: photo, at: url) }
        defer { edits[photo] = edit }
        guard edit.unsaved != .unreadable else { return }
        // Back to what's on disk: nothing to write, and no reason to ask for access.
        if edit.history.recipe == edit.sidecar?.recipe ?? edit.cameraEdit, !(reverting && edit.sidecar != nil) {
            edit.unsaved = nil
            return
        }
        guard ensureCanWrite(nextTo: url) else {
            edit.unsaved = .noAccess
            return
        }
        do {
            if reverting {
                try Sidecar.delete(for: url)
                edit.sidecar = nil
            } else {
                edit.sidecar = try Sidecar.save(edit.history.recipe, for: url, over: edit.sidecar, asShot: edit.cameraEdit)
            }
            edit.unsaved = nil
        } catch {
            edit.unsaved = .failed
            errorMessage = reverting
                ? "The edit to “\(photo.name)” couldn't be removed. (\(error.localizedDescription))"
                : "The edit to “\(photo.name)” couldn't be saved. (\(error.localizedDescription))"
        }
        if let index = contents[photo.folder]?.photos.firstIndex(where: { $0.name == photo.name }) {
            contents[photo.folder]?.photos[index].isEdited = edit.sidecar != nil
        }
        // Like a rating change, an edit doesn't make the photo vanish from the Edited filter.
        changedPhotos.insert(photo)
    }

    /// Renders the thumbnails of photos edited since Proof started again, after the LUT library
    /// changes: a look whose LUT appeared or went missing shows differently.
    private func refreshEditedThumbnails() {
        for photo in editedThumbnails.keys {
            if let url = url(ofPhoto: photo.name, in: photo.folder) { refreshThumbnail(of: photo, at: url) }
        }
    }

    /// Renders the photo's thumbnail with its current edit off the main thread. A result that
    /// arrives after a newer change is dropped.
    private func refreshThumbnail(of photo: PhotoReference, at url: URL) {
        guard let recipe = edits[photo]?.history.recipe else { return }
        Task {
            let image = await Task.detached { await ThumbnailCache.shared.thumbnail(for: url, edit: recipe) }.value
            guard let image, edits[photo]?.history.recipe == recipe else { return }
            editedThumbnails[photo] = image
        }
    }

    /// The file of the selected photo.
    public var selectedPhotoURL: URL? {
        guard let photo = browse.selectedPhoto else { return nil }
        return url(ofPhoto: photo.name, in: photo.folder)
    }

    /// The file for a photo listed in `folder`. A saved location that is a single photo is its own folder.
    public func url(ofPhoto name: String, in folder: FileReference) -> URL? {
        guard let fileAccess, let folderURL = fileAccess.url(for: folder) else { return nil }
        let isDirectory = (try? folderURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        guard isDirectory else { return folderURL }
        return fileAccess.url(for: FileReference(locationID: folder.locationID,
                                                 relativePath: folder.relativePath + [name]))
    }

    /// Whether Proof may write a sidecar next to `photo`. When it can't, the person is asked
    /// to grant the photo's saved folder again, once (decision 0007), and this returns `false`;
    /// the caller keeps its change in memory until a later call returns `true`.
    public func ensureCanWrite(nextTo photo: URL) -> Bool {
        guard let fileAccess else { return false }
        if fileAccess.canWrite(to: photo) { return true }
        // The picker opens by itself once per folder; after that the inspector offers it. A
        // location that is a single photo is granted through its folder (decision 0008).
        if let location = fileAccess.location(containing: photo), !isChoosingFolder,
           askedForWriteAccess.insert(location.id).inserted {
            requestFolder(.grantWrite(location))
        }
        return false
    }

    /// Opens the folder picker to grant the selected photo's folder again, for the inspector's button.
    public func grantWriteAccessForSelectedPhoto() {
        guard let photo = browse.selectedPhoto,
              let location = locations.first(where: { $0.id == photo.folder.locationID }) else { return }
        requestFolder(.grantWrite(location))
    }

    /// Where the folder picker opens: the folder being granted again, otherwise the system default.
    public var folderPickerDirectory: URL? {
        if case .grantWrite(let location) = folderRequest { FileAccess.writeGrantFolder(for: location.lastKnownURL) } else { nil }
    }

    public var folderPickerMessage: String {
        switch folderRequest {
        case .add: ""
        case .locate(let location): "Choose where “\(location.name)” is now."
        case .grantWrite(let location):
            "Proof needs permission to save edits in “\(FileAccess.writeGrantFolder(for: location.lastKnownURL).lastPathComponent)”. Your photos are never changed."
        }
    }

    public var folderPickerConfirmation: String {
        if case .grantWrite = folderRequest { "Grant Access" } else { "Open" }
    }

    public func requestFolder(_ request: FolderRequest) {
        folderRequest = request
        isChoosingFolder = true
    }

    /// Whether the folder picker lets several folders be chosen at once: only when adding.
    public var folderPickerAllowsSeveral: Bool {
        if case .add = folderRequest { true } else { false }
    }

    /// The folders chosen in a picker that allows several. Locate and Grant Access take the first.
    public func chose(_ urls: [URL]) {
        guard case .add = folderRequest else {
            if let url = urls.first { chose(url) }
            return
        }
        guard let fileAccess, !urls.isEmpty else { return }
        do {
            let added = try fileAccess.add(urls)
            refreshLocations()
            selection = added.first.flatMap { fileAccess.reference(for: $0.lastKnownURL) }.map(SidebarItem.folder)
        } catch {
            refreshLocations()
            errorMessage = error.localizedDescription
        }
    }

    public func chose(_ url: URL) {
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
                if selection?.isAcrossFolders == true { readAllPhotos() }
            case .grantWrite(let location):
                try fileAccess.grantWriteAccess(location.id, with: url)
                refreshLocations()
                // A single photo became its folder: list the folder's photos, as with Locate.
                if location.lastKnownURL.standardizedFileURL != url.standardizedFileURL {
                    contents = contents.filter { $0.key.locationID != location.id }
                    Task { await load(FileReference(locationID: location.id, relativePath: []), force: true) }
                    if selection?.isAcrossFolders == true { readAllPhotos() }
                }
                for (photo, edit) in edits where photo.folder.locationID == location.id && edit.unsaved == .noAccess {
                    save(photo)
                }
                for photo in unsavedMetadata where photo.folder.locationID == location.id {
                    saveMetadata(of: photo)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Forgets a saved folder. Photos and edits on disk are not touched.
    public func remove(_ location: SavedLocation) {
        do {
            try fileAccess?.remove(location.id)
        } catch {
            errorMessage = error.localizedDescription
        }
        contents = contents.filter { $0.key.locationID != location.id }
        if selection?.folder?.locationID == location.id { selection = nil }
        refreshLocations()
        if selection?.isAcrossFolders == true { readAllPhotos() }
    }

    /// Reads every folder already read again, on local disks and network volumes, after checking
    /// which saved folders are available. For View › Reload Folders.
    public func refresh() {
        recheckLocations()
        reload(contents.keys.filter { isAvailable($0.locationID) })
    }

    /// Reads `folder` and the subfolders of it already read again, for the sidebar's Refresh.
    public func refresh(_ folder: FileReference) {
        recheckLocations()
        guard isAvailable(folder.locationID) else { return }
        reload(contents.keys.filter { folder.contains($0) } + [folder])
    }

    /// The files of the selected photos, or of the selected folder when no photo is selected, for the menu
    /// bar's Show in Finder and Copy Path. Photos or folders that can't be reached are left out.
    public var selectedFileURLs: [URL] {
        let photos = selectedPhotosInOrder
        if !photos.isEmpty { return urls(of: photos) }
        if case .folder(let folder) = selection, let url = fileAccess?.url(for: folder) { return [url] }
        return []
    }

    /// Whether a photo or a folder is selected, without looking up their files, for the menu bar.
    public var hasSelectedFiles: Bool {
        if !browse.selectedPhotos.isEmpty { return true }
        if case .folder = selection { return true }
        return false
    }

    public func urls(of photos: [PhotoReference]) -> [URL] {
        photos.compactMap { url(ofPhoto: $0.name, in: $0.folder) }
    }

    public func url(of folder: FileReference) -> URL? {
        fileAccess?.url(for: folder)
    }

    /// Opens a Finder window with the files selected, so their location is visible.
    public func showInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        platform.revealFiles(urls)
    }

    /// Puts the paths on the pasteboard, one per line, as Finder's Copy as Pathname does.
    public func copyPaths(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        platform.copyString(urls.map(\.path).joined(separator: "\n"))
    }

    /// Follows changes Proof is told about: drives and shares connecting and disconnecting, and
    /// Proof becoming the active app, when folders that aren't watched are read again.
    private func observeSystem() {
        platform.observe { [weak self] event in
            guard let self else { return }
            switch event {
            case .volumesChanged:
                recheckLocations()
            case .becameActive:
                // Coming back from the Finder, where LUTs may have been added, moved or removed.
                looks.reload()
                becameActive()
            case .willTerminate:
                // A change made just before quitting hasn't been committed yet.
                if let photo = browse.selectedPhoto { commitEdit(of: photo) }
            }
        }
    }

    private func becameActive() {
        recheckLocations()
        // Folders that aren't watched: those on network volumes, and on iOS every folder.
        reload(contents.keys.filter { !FolderWatcher.reportsChanges || networkLocations.contains($0.locationID) })
    }

    /// Resolves the saved locations again, so a folder whose drive connected becomes available
    /// and one whose drive went away shows as offline.
    private func recheckLocations() {
        guard let fileAccess else { return }
        let before = statuses
        statuses = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, fileAccess.recheck($0.id)) })
        // A folder found again after it was moved or renamed has a new name.
        if locations != fileAccess.locations { locations = fileAccess.locations }
        guard statuses != before else { return }
        // What was read on a drive that went away is forgotten, so it is read fresh when it returns.
        contents = contents.filter { isAvailable($0.key.locationID) }
        watchLocalFolders()
        browse.keep(only: visiblePhotos)
        if selection?.isAcrossFolders == true { readAllPhotos() }
        // The sidebar reads the folders it shows, but a selected subfolder may be collapsed out of view.
        if let folder = selection?.folder, isAvailable(folder.locationID) {
            Task { await load(folder) }
        }
    }

    /// Watches the available saved folders on local disks with FSEvents. Locations that are a
    /// single photo aren't watched.
    private func watchLocalFolders() {
        var local: [URL] = []
        networkLocations = []
        for location in locations {
            guard case .available(let url) = status(of: location.id) else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .volumeIsLocalKey])
            if values?.volumeIsLocal == false {
                networkLocations.insert(location.id)
            } else if values?.isDirectory == true {
                local.append(url)
            }
        }
        watcher = FolderWatcher(folders: local) { [weak self] changes in self?.foldersChanged(changes) }
    }

    /// Reads again the folders FSEvents reported, if they've been read.
    private func foldersChanged(_ changes: [FolderWatcher.Change]) {
        guard let fileAccess else { return }
        let changed = changes.compactMap { change in
            fileAccess.reference(for: change.folder).map { (folder: $0, includesSubfolders: change.includesSubfolders) }
        }
        reload(contents.keys.filter { folder in
            changed.contains { change in
                change.folder.locationID == folder.locationID
                    && (change.includesSubfolders ? folder.relativePath.starts(with: change.folder.relativePath)
                                                  : folder.relativePath == change.folder.relativePath)
            }
        })
    }

    /// Reads `folders` again in sidebar order. For All Photos, new subfolders are read afterwards.
    private func reload(_ folders: [FileReference]) {
        guard !folders.isEmpty else { return }
        let ordered = folders.sorted { $0.relativePath.count < $1.relativePath.count }
        Task {
            for folder in ordered { await load(folder, force: true) }
            if selection?.isAcrossFolders == true { readAllPhotos() }
        }
    }

    private func refreshLocations() {
        guard let fileAccess else { return }
        // Resolving never mounts a volume, so this doesn't wait on a disconnected NAS. It follows
        // folders that were moved or renamed, so the locations are read after it.
        statuses = Dictionary(uniqueKeysWithValues: fileAccess.locations.map { ($0.id, fileAccess.resolve($0.id)) })
        locations = fileAccess.locations
        watchLocalFolders()
    }
}

