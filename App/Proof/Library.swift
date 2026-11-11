import AppKit
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

/// One photo's edit while Proof runs. Kept for every photo opened in Edit until Proof quits, so
/// each photo has its own undo history.
struct PhotoEdit {
    /// Why the current edit isn't on disk.
    enum Unsaved {
        /// The folder, or a photo saved on its own, was saved before Proof could write and
        /// hasn't been granted again.
        case noAccess
        /// The sidecar couldn't be read, so it isn't written over.
        case unreadable
        case failed
    }

    /// What the canvas and controls show. Ahead of `history.recipe` while a change is being made.
    var recipe: EditRecipe
    var history: EditHistory
    /// The sidecar as last read or written; `nil` when there is none.
    var sidecar: Sidecar?
    /// ISO, focal length, aperture and shutter speed, shown under the histogram. Read once the
    /// photo is opened.
    var captureSettings: CaptureSettings?
    var unsaved: Unsaved?
    /// The camera's white balance, which the white balance controls show for As Shot. `nil`
    /// until it has been read from the photo.
    var asShot: WhiteBalance?
    /// The camera's sharpening and noise reduction, which the Detail sliders show where the edit
    /// has none. `nil` until it has been read from the photo.
    var cameraDetail: CameraDetail?
    /// The lens and whether the file has a correction profile, which the Lens Corrections card
    /// shows. `nil` until it has been read from the photo.
    var cameraLens: CameraLens?
    /// The photo's size in pixels as the camera oriented it, which the crop tool lays out by.
    /// `nil` until it has been read from the photo.
    var size: CGSize?
}

/// The saved folders, what has been read of them, which folder, filter and photo are chosen, and
/// whether that photo is being edited. Shared by the sidebar, the grid, the toolbar and the menus.
@Observable @MainActor
final class Library {
    /// Why the folder picker is open.
    enum FolderRequest {
        case add
        case locate(SavedLocation)
        /// A folder saved with a read-only grant, chosen again so Proof can write sidecars in it.
        case grantWrite(SavedLocation)
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
    var browse = BrowseState() {
        didSet {
            guard browse.selectedPhoto != oldValue.selectedPhoto || browse.mode != oldValue.mode else { return }
            // Leaving the photo any way but Done or Cancel keeps the crop.
            if isCropping, let previous = oldValue.selectedPhoto { endCropping(of: previous) }
            isPickingWhiteBalance = false
            isDrawingGuides = false
            if let previous = oldValue.selectedPhoto { commitEdit(of: previous) }
            openSelectedEdit()
            offGroups = AdjustmentGroup.initiallyOff(for: selectedEdit?.recipe)
        }
    }
    /// The edits of photos opened in Edit since Proof started.
    private(set) var edits: [PhotoReference: PhotoEdit] = [:]
    /// Thumbnails of photos edited since Proof started, showing their current edit. The grid and
    /// the filmstrip show these over the thumbnails they loaded.
    private(set) var editedThumbnails: [PhotoReference: NSImage] = [:]
    /// Groups switched off: the canvas shows the photo without their adjustments, to compare, and
    /// their cards are closed. Only the view changes: the edit keeps the adjustments, and opening
    /// a photo sets the switches again.
    var offGroups: Set<AdjustmentGroup> = []

    func isOn(_ group: AdjustmentGroup) -> Bool {
        !offGroups.contains(group)
    }

    func setOn(_ group: AdjustmentGroup, _ isOn: Bool) {
        showEdited()
        if isOn { offGroups.remove(group) } else { offGroups.insert(group) }
    }
    /// A control is being dragged. The change becomes one undo step, and is saved, when it ends.
    var isAdjusting = false {
        didSet {
            commitTask?.cancel()
            if !isAdjusting, let photo = browse.selectedPhoto { commitEdit(of: photo) }
        }
    }
    /// The Distortion slider or a Transform slider is being dragged, which shows a grid over the photo.
    var isAdjustingGeometry = false
    var isInspectorShown = true
    /// How far the photo in Edit is zoomed and where; back to Fit for each photo and for the crop tool.
    let zoom = CanvasZoom()
    /// The LUT library and its previews of the photo in Edit, for the Look section.
    let looks = LookBrowser()
    var isChoosingFolder = false
    /// Kept apart from `isChoosingFolder`, which SwiftUI clears before the picker's result arrives.
    private(set) var folderRequest: FolderRequest = .add
    var errorMessage: String?
    /// The histogram of the latest render shown on the canvas, and the photo it was measured from.
    private var histogram: (url: URL, value: Histogram)?

    /// The histogram of the selected photo. Nil until its first render has been measured, so
    /// another photo's histogram is never shown in its place.
    var selectedHistogram: Histogram? {
        guard let histogram, histogram.url == selectedPhotoURL else { return nil }
        return histogram.value
    }

    func showHistogram(_ histogram: Histogram, of url: URL) {
        self.histogram = (url, histogram)
    }

    private let fileAccess: FileAccess?
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
    /// visible even if the filter no longer matches, so a photo doesn't vanish while it's rated.
    private var changedPhotos: Set<PhotoReference> = []
    /// Photos whose rating or flag couldn't be saved yet because their folder has a read-only grant.
    private(set) var unsavedMetadata: Set<PhotoReference> = []
    /// The latest XMP write. Each waits for the one before, so quick changes land in order.
    private var metadataWrite: Task<Void, Never>?
    private static let selectionKey = "selectedFolder"

    init() {
        fileAccess = try? FileAccess(storeURL: URL.applicationSupportDirectory
            .appendingPathComponent("Proof/locations.json"))
        if fileAccess == nil { errorMessage = "Proof couldn't load its saved folders." }
        refreshLocations()
        observeSystem()
        looks.onChange = { [weak self] in self?.refreshEditedThumbnails() }
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
        isAvailable(location.id)
    }

    private func isAvailable(_ id: UUID) -> Bool {
        if case .available = status(of: id) { true } else { false }
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
        contents[folder] = (read ?? FolderContents(subfolders: [], photos: [])).keepingMetadata(from: contents[folder])
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

    /// Sets the selected photo's stars and saves them to its XMP sidecar.
    func setRating(_ rating: Int) {
        changeSelectedMetadata { $0.rating = rating }
    }

    /// Sets the selected photo's flag and saves it to its XMP sidecar.
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
        saveMetadata(of: photo)
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

    // MARK: Edits

    /// The edit of the photo open in Edit.
    var selectedEdit: PhotoEdit? {
        browse.selectedPhoto.flatMap { edits[$0] }
    }

    /// Changes the selected photo's edit. Outside a drag, the change is committed once the
    /// controls are idle, so a burst of key presses is one undo step.
    func changeEdit(_ change: (inout EditRecipe) -> Void) {
        guard let photo = browse.selectedPhoto, edits[photo] != nil else { return }
        showEdited()
        change(&edits[photo]!.recipe)
        commitTask?.cancel()
        guard !isAdjusting else { return }
        commitTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            commitEdit(of: photo)
        }
    }

    /// Photo › Next Look and Previous Look can step through the shown folder's looks.
    var canStepLook: Bool {
        isEditing && selectedEdit != nil && !looks.shownNames.isEmpty
    }

    /// Chooses the look `offset` places from the current one in the folder the Looks section
    /// shows, keeping its strength. Without a look, starts at the first or last.
    func stepLook(by offset: Int) {
        guard canStepLook, let next = looks.look(steppingBy: offset, from: selectedEdit?.recipe.look?.lut) else { return }
        setOn(.look, true)
        changeEdit { recipe in
            recipe.look = Look(lut: next, strength: recipe.look?.strength ?? 1)
        }
    }

    var canUndoEdit: Bool {
        guard let edit = selectedEdit else { return false }
        return edit.history.canUndo || edit.recipe != edit.history.recipe
    }

    var canRedoEdit: Bool {
        selectedEdit?.history.canRedo == true
    }

    func undoEdit() {
        stepEdit { $0.undo() }
    }

    func redoEdit() {
        stepEdit { $0.redo() }
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

    /// The selected photo has an edit to revert, whatever its undo history.
    var canRevertEdit: Bool {
        guard let edit = selectedEdit else { return false }
        return !edit.recipe.isNeutral || edit.sidecar != nil
    }

    /// Photo › Revert to Original: makes the edit neutral as one undo step, without asking, and
    /// deletes the sidecar (decision 0007). Undo writes the edit back as a new sidecar.
    func revertEdit() {
        guard let photo = browse.selectedPhoto else { return }
        commitTask?.cancel()
        commitEdit(of: photo)
        guard var edit = edits[photo] else { return }
        showEdited()
        edit.history.record(EditRecipe())
        edit.recipe = EditRecipe()
        edits[photo] = edit
        save(photo, reverting: true)
    }

    /// Photo › Show Original (backslash): the photo without its edit, to compare. Any change to
    /// the edit, and the crop tool and eyedropper, show the edited photo again, so a change is
    /// never made out of sight.
    func toggleOriginal() {
        guard isEditing, !isCropping, !isPickingWhiteBalance, selectedEdit != nil else { return }
        browse.toggleOriginal()
    }

    private func showEdited() {
        if browse.isShowingOriginal { browse.showEdited() }
    }

    /// Reads the selected photo's sidecar the first time it is opened in Edit. Later visits keep
    /// the edit and its undo history from memory.
    private func openSelectedEdit() {
        guard isEditing, let photo = browse.selectedPhoto, edits[photo] == nil, let url = selectedPhotoURL else { return }
        do {
            let sidecar = try Sidecar.read(for: url)
            let recipe = sidecar?.recipe ?? EditRecipe()
            edits[photo] = PhotoEdit(recipe: recipe, history: EditHistory(recipe), sidecar: sidecar)
        } catch {
            edits[photo] = PhotoEdit(recipe: EditRecipe(), history: EditHistory(EditRecipe()), unsaved: .unreadable)
        }
        // Off the main thread: it opens the RAW file, which can be slow on a network volume.
        Task {
            let (asShot, cameraDetail, cameraLens, settings, size) = await Task.detached {
                (WhiteBalance.asShot(of: url), CameraDetail.of(url), CameraLens.of(url), CaptureSettings.read(from: url),
                 RAWRenderer.orientedSize(of: url))
            }.value
            edits[photo]?.asShot = asShot
            edits[photo]?.cameraDetail = cameraDetail
            edits[photo]?.cameraLens = cameraLens
            edits[photo]?.captureSettings = settings
            edits[photo]?.size = size
        }
    }

    // MARK: Crop

    /// The crop tool is open on the selected photo.
    private(set) var isCropping = false
    /// The straighten slider is being dragged, which shows a finer grid over the photo.
    var isStraightening = false
    /// The edit when the crop tool opened, which Cancel returns to.
    private var recipeBeforeCrop: EditRecipe?
    /// The rectangle as it was before straightening shrank it, so it grows back as the angle
    /// returns toward zero.
    private var unstraightenedFrame: CropFrame?
    /// The next drag on the photo draws a line to level the photo along, instead of moving the rectangle.
    var isDrawingLevelLine = false
    /// Auto is looking for the horizon.
    private(set) var isFindingHorizon = false
    /// Auto found no horizon, which the crop tool shows for a moment.
    private(set) var foundNoHorizon = false
    /// Auto white balance or Auto Tone is measuring the photo.
    private(set) var isAutoAdjusting = false
    /// The White Balance eyedropper is waiting for a click on something neutral in the photo.
    var isPickingWhiteBalance = false

    /// The selected photo's crop. A photo without one starts locked to its own shape (Original).
    var selectedCrop: Crop {
        selectedEdit?.recipe.crop ?? Crop.uncropped(photoSize: selectedEdit?.size)
    }

    /// The selected photo turned and flipped, in pixels: the space the crop rectangle is in.
    /// `nil` until the photo's size has been read.
    var turnedPhotoSize: CGSize? {
        selectedEdit?.size.map { selectedCrop.turnedSize(of: $0) }
    }

    /// The crop rectangle of the selected photo, in the units of `turnedPhotoSize`.
    var selectedCropFrame: CropFrame? {
        turnedPhotoSize.map { CropFrame(selectedCrop, imageSize: $0) }
    }

    func startCropping() {
        guard isEditing, !isCropping, let photo = browse.selectedPhoto, let edit = edits[photo] else { return }
        commitTask?.cancel()
        commitEdit(of: photo)
        recipeBeforeCrop = edit.recipe
        showEdited()
        unstraightenedFrame = nil
        isPickingWhiteBalance = false
        isDrawingGuides = false
        isCropping = true
    }

    /// Done: keeps the crop and closes the tool.
    func finishCropping() {
        guard isCropping, let photo = browse.selectedPhoto else { return }
        endCropping(of: photo)
        commitEdit(of: photo)
    }

    /// Cancel: returns to the edit from when the tool opened, as one undo step.
    func cancelCropping() {
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
    func setCropFrame(_ frame: CropFrame) {
        unstraightenedFrame = frame
        changeCrop { frame.applied(to: $0) }
    }

    /// Sets the straighten angle, shrinking the rectangle as needed to keep it on the photo.
    func setStraighten(_ angle: Double) {
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

    /// Straightens so the line drawn from `start` to `end`, in points on the photo as shown,
    /// becomes level or upright, and ends drawing. A click without a drag changes nothing.
    func level(from start: CGPoint, to end: CGPoint) {
        isDrawingLevelLine = false
        guard let correction = Horizon.correction(from: start, to: end, minimumLength: 8) else { return }
        setStraighten(selectedCrop.angle + correction)
    }

    /// Sets the selected photo's white balance to the one Auto estimates, labelled Auto.
    func autoWhiteBalance(with renderer: RAWRenderer) async {
        await autoAdjust(with: renderer, what: "white balance") { renderer, recipe in
            let found = try await renderer.autoWhiteBalance(recipe: recipe)
            return { $0.basic.setAuto(found) }
        }
    }

    /// Opens or closes the White Balance eyedropper.
    func toggleWhiteBalancePicker() {
        guard isEditing, !isCropping, selectedEdit?.asShot != nil else { return }
        showEdited()
        isPickingWhiteBalance.toggle()
    }

    /// Sets the white balance that makes `patch` of the selected photo neutral gray, as Custom,
    /// and closes the eyedropper, as Lightroom's closes after one click. A patch too dark to tell
    /// its color beeps and leaves the eyedropper open for another try.
    func pickWhiteBalance(in patch: CGRect, with renderer: RAWRenderer) async {
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
            NSSound.beep()
        } else {
            setOn(.whiteBalance, true)
            isPickingWhiteBalance = false
        }
    }

    /// Sets the selected photo's six Tone sliders to the values Auto estimates.
    func autoTone(with renderer: RAWRenderer) async {
        await autoAdjust(with: renderer, what: "tone") { renderer, recipe in
            let light = try await renderer.autoTone(recipe: recipe)
            return { light.apply(to: &$0.basic) }
        }
    }

    /// Remove Chromatic Aberration is measuring the selected photo. Its switch shows on meanwhile,
    /// with a spinner, so turning it on answers at once.
    private(set) var isMeasuringChromaticAberration = false

    /// Turns Remove Chromatic Aberration on, measuring the selected photo's fringes, or off.
    func setRemovesChromaticAberration(_ isOn: Bool, with renderer: RAWRenderer) async {
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
    private(set) var isFindingLines = false
    /// Upright found no lines to go by, which the Transform card shows for a moment.
    private(set) var foundNoLines = false
    /// Guided is open: a drag on the photo draws a line to make upright or level.
    var isDrawingGuides = false
    /// The lines found in a photo, kept while its lens corrections stay the same, so trying
    /// each Upright mode in turn doesn't look again.
    private var foundLines: (photo: PhotoReference, lens: LensCorrections, segments: [LineSegment], size: CGSize)?

    /// The most guides Guided keeps, as in Lightroom: two each way pin every slider it sets.
    static let maximumGuides = 4

    /// Sets the Transform sliders as Upright `mode` chooses them, or returns them to none for
    /// `nil` (Off). Aspect, Scale and the offsets are kept. Guided opens the guide tool instead,
    /// keeping guides drawn before. Upright straightens the photo itself, so the crop's
    /// straighten angle goes back to zero, as Lightroom resets it.
    func setUpright(_ mode: UprightMode?, with renderer: RAWRenderer) async {
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
            guard let solved = Upright.solve(mode, segments: found.segments, size: found.size,
                                             from: recipe.transform) else {
                foundNoLines = true
                try? await Task.sleep(for: .seconds(2))
                foundNoLines = false
                return
            }
            changeEdit { recipe in
                recipe.transform = solved
                recipe.crop?.angle = 0
            }
        }
    }

    /// Adds a guide, from 0 to 1 on each axis of the uncorrected photo, replacing the oldest once
    /// there are `maximumGuides`, and straightens to the guides.
    func addGuide(_ guide: GuideLine) {
        let size = selectedEdit?.size
        changeEdit { recipe in
            recipe.transform.guides = Array((recipe.transform.guides + [guide]).suffix(Self.maximumGuides))
            recipe.transform.upright = .guided
            recipe.transform = Self.solveGuides(recipe.transform, size: size)
            recipe.crop?.angle = 0
        }
    }

    /// Removes the guides and the correction they made.
    func clearGuides() {
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
    private func autoAdjust(with renderer: RAWRenderer, what: String,
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
        changeEdit(change)
    }

    /// Straightens to the horizon Vision finds in the selected photo. When there is none, the
    /// angle stays as it was and `foundNoHorizon` is set for two seconds.
    func autoStraighten(with renderer: RAWRenderer) async {
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
    func setCropAspect(_ aspect: AspectRatio?) {
        guard let current = selectedCropFrame else { return }
        unstraightenedFrame = nil
        changeCrop { crop in
            var crop = crop
            crop.aspect = aspect
            return current.withAspect(aspect).applied(to: crop)
        }
    }

    /// Switches the rectangle between landscape and portrait. Freeform stays freeform.
    func swapCropOrientation() {
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
    var originalAspect: AspectRatio? {
        turnedPhotoSize.map { AspectRatio($0.width, $0.height) }
    }

    func rotate(clockwise: Bool) {
        unstraightenedFrame = nil
        changeCrop { var crop = $0; crop.rotate(clockwise: clockwise); return crop }
    }

    func flipHorizontally() {
        unstraightenedFrame = nil
        changeCrop { var crop = $0; crop.flipHorizontally(); return crop }
    }

    func flipVertically() {
        unstraightenedFrame = nil
        changeCrop { var crop = $0; crop.flipVertically(); return crop }
    }

    /// Removes the rectangle and straighten and locks the ratio to Original, keeping the turn and flips.
    func resetCropRectangle() {
        unstraightenedFrame = nil
        let original = originalAspect
        changeCrop { Crop(rotation: $0.rotation, flipHorizontal: $0.flipHorizontal, flipVertical: $0.flipVertical,
                          aspect: original) }
    }

    /// Whether the crop differs from where the crop tool starts: the whole photo, locked to Original.
    var canResetCropRectangle: Bool {
        let crop = selectedCrop
        guard let original = originalAspect, let aspect = crop.aspect else { return crop.hasRectangle || crop.aspect == nil }
        return crop.hasRectangle || !aspect.matches(original)
    }

    /// Undoes the turn and flips, keeping the rectangle on the same part of the photo.
    func resetCropTurn() {
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

    /// Makes the photo's current change one undo step and saves it.
    private func commitEdit(of photo: PhotoReference) {
        guard var edit = edits[photo], edit.history.record(edit.recipe) else { return }
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
        if edit.history.recipe == edit.sidecar?.recipe ?? EditRecipe(), !(reverting && edit.sidecar != nil) {
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
                edit.sidecar = try Sidecar.save(edit.history.recipe, for: url, over: edit.sidecar)
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
            let image = await Task.detached { await ThumbnailGrid.cache.thumbnail(for: url, edit: recipe) }.value
            guard let image, edits[photo]?.history.recipe == recipe else { return }
            editedThumbnails[photo] = NSImage(cgImage: image, size: .zero)
        }
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

    /// Whether Proof may write a sidecar next to `photo`. When it can't, the person is asked
    /// to grant the photo's saved folder again, once (decision 0007), and this returns `false`;
    /// the caller keeps its change in memory until a later call returns `true`.
    func ensureCanWrite(nextTo photo: URL) -> Bool {
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
    func grantWriteAccessForSelectedPhoto() {
        guard let photo = browse.selectedPhoto,
              let location = locations.first(where: { $0.id == photo.folder.locationID }) else { return }
        requestFolder(.grantWrite(location))
    }

    /// Where the folder picker opens: the folder being granted again, otherwise the system default.
    var folderPickerDirectory: URL? {
        if case .grantWrite(let location) = folderRequest { FileAccess.writeGrantFolder(for: location.lastKnownURL) } else { nil }
    }

    var folderPickerMessage: String {
        switch folderRequest {
        case .add: ""
        case .locate(let location): "Choose where “\(location.name)” is now."
        case .grantWrite(let location):
            "Proof needs permission to save edits in “\(FileAccess.writeGrantFolder(for: location.lastKnownURL).lastPathComponent)”. Your photos are never changed."
        }
    }

    var folderPickerConfirmation: String {
        if case .grantWrite = folderRequest { "Grant Access" } else { "Open" }
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
            case .grantWrite(let location):
                try fileAccess.grantWriteAccess(location.id, with: url)
                refreshLocations()
                // A single photo became its folder: list the folder's photos, as with Locate.
                if location.lastKnownURL.standardizedFileURL != url.standardizedFileURL {
                    contents = contents.filter { $0.key.locationID != location.id }
                    Task { await load(FileReference(locationID: location.id, relativePath: []), force: true) }
                    if selection == .allPhotos { readAllPhotos() }
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

    /// Reads every folder already read again, on local disks and network volumes, after checking
    /// which saved folders are available. For View › Reload Folders.
    func refresh() {
        recheckLocations()
        reload(contents.keys.filter { isAvailable($0.locationID) })
    }

    /// Follows changes Proof is told about: drives and shares connecting and disconnecting, and
    /// Proof becoming the active app, when folders on network volumes are read again.
    private func observeSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.recheckLocations() }
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.becameActive() }
        }
        // A change made just before quitting hasn't been committed yet.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let photo = self?.browse.selectedPhoto { self?.commitEdit(of: photo) }
            }
        }
    }

    private func becameActive() {
        recheckLocations()
        reload(contents.keys.filter { networkLocations.contains($0.locationID) })
    }

    /// Resolves the saved locations again, so a folder whose drive connected becomes available
    /// and one whose drive went away shows as offline.
    private func recheckLocations() {
        guard let fileAccess else { return }
        let before = statuses
        statuses = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, fileAccess.recheck($0.id)) })
        guard statuses != before else { return }
        // What was read on a drive that went away is forgotten, so it is read fresh when it returns.
        contents = contents.filter { isAvailable($0.key.locationID) }
        watchLocalFolders()
        browse.keep(only: visiblePhotos)
        if selection == .allPhotos { readAllPhotos() }
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
            if selection == .allPhotos { readAllPhotos() }
        }
    }

    private func refreshLocations() {
        guard let fileAccess else { return }
        locations = fileAccess.locations
        // Resolving never mounts a volume, so this doesn't wait on a disconnected NAS.
        statuses = Dictionary(uniqueKeysWithValues: locations.map { ($0.id, fileAccess.resolve($0.id)) })
        watchLocalFolders()
    }
}

