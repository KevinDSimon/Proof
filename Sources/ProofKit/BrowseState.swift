import Foundation

/// Whether the window is browsing photos or editing one of them, and which photos are selected.
/// Photos are identified by folder and file name, since All Photos shows several folders at once.
///
/// Several photos can be selected, as in Finder: ⌘-click adds or removes one, ⇧-click a range,
/// ⌘A all of them. One of them is `selectedPhoto`, the photo Edit shows. Adding to the selection
/// keeps it, so the photo in Edit doesn't change while photos are added from the filmstrip.
public struct BrowseState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case browsing
        case editing
    }

    public enum Move: Sendable {
        case left, right, up, down
    }

    public private(set) var mode: Mode = .browsing {
        didSet { if mode != oldValue { isShowingOriginal = false } }
    }
    /// The photo Edit shows, which is always among `selectedPhotos`. Setting it selects only that
    /// photo, as a plain click or an arrow key does. Clearing it also leaves Edit, since there is
    /// no photo left to edit.
    public var selectedPhoto: PhotoReference? {
        didSet {
            if !isExtendingSelection {
                selectedPhotos = selectedPhoto.map { [$0] } ?? []
                anchor = selectedPhoto
                selectionAtAnchor = selectedPhotos
            }
            if selectedPhoto == nil { mode = .browsing }
            if selectedPhoto != oldValue { isShowingOriginal = false }
        }
    }
    /// Every selected photo, including `selectedPhoto`. Ratings, flags, Paste Settings and Revert
    /// to Original apply to all of them.
    public private(set) var selectedPhotos: Set<PhotoReference> = []
    /// Where a ⇧-click range starts: the photo last clicked without ⇧.
    private var anchor: PhotoReference?
    /// The selection when the anchor was set. A ⇧-click range adds to it, and a later ⇧-click
    /// replaces the range rather than adding another one, as in Finder.
    private var selectionAtAnchor: Set<PhotoReference> = []
    private var isExtendingSelection = false
    /// In Edit, the photo is shown without its edit, to compare. Leaving the photo or Edit ends it.
    public private(set) var isShowingOriginal = false

    public init(selectedPhoto: PhotoReference? = nil) {
        self.selectedPhoto = selectedPhoto
        selectedPhotos = selectedPhoto.map { [$0] } ?? []
        anchor = selectedPhoto
        selectionAtAnchor = selectedPhotos
    }

    /// More than one photo is selected.
    public var hasMultipleSelection: Bool {
        selectedPhotos.count > 1
    }

    /// The selected photos in the order `photos` shows them.
    public func selected(in photos: [ListedPhoto]) -> [PhotoReference] {
        photos.map(\.id).filter { selectedPhotos.contains($0) }
    }

    /// ⌘-click: adds the photo to the selection, or removes it. Removing the photo Edit shows
    /// moves it to the nearest selected photo after it, or before it at the end. Removing the
    /// last selected photo clears the selection.
    public mutating func toggle(_ photo: PhotoReference, in photos: [ListedPhoto]) {
        var selection = selectedPhotos
        if selection.contains(photo) { selection.remove(photo) } else { selection.insert(photo) }
        let primary = if selectedPhoto == photo, !selection.contains(photo) {
            nearest(to: photo, among: selection, in: photos)
        } else {
            selectedPhoto ?? photo
        }
        setSelection(selection, primary: primary)
        anchor = photo
        selectionAtAnchor = selection
    }

    /// ⇧-click: selects every photo from the anchor to this one, added to what was selected when
    /// the anchor was set. Without an anchor it selects only this photo.
    public mutating func extend(to photo: PhotoReference, in photos: [ListedPhoto]) {
        guard let anchor, let from = photos.firstIndex(where: { $0.id == anchor }),
              let to = photos.firstIndex(where: { $0.id == photo }) else {
            selectedPhoto = photo
            return
        }
        let range = photos[min(from, to)...max(from, to)].map(\.id)
        let selection = selectionAtAnchor.union(range)
        setSelection(selection, primary: selectedPhoto.flatMap { selection.contains($0) ? $0 : nil } ?? photo)
    }

    /// ⌘A: selects every photo in `photos`, keeping the photo Edit shows.
    public mutating func selectAll(_ photos: [ListedPhoto]) {
        guard !photos.isEmpty else { return }
        let selection = Set(photos.map(\.id))
        let primary = selectedPhoto.flatMap { selection.contains($0) ? $0 : nil } ?? photos[0].id
        setSelection(selection, primary: primary)
        anchor = primary
        selectionAtAnchor = selection
    }

    /// Keeps only the photo Edit shows selected.
    public mutating func selectOnlyCurrent() {
        let current = selectedPhoto
        selectedPhoto = current
    }

    private mutating func setSelection(_ selection: Set<PhotoReference>, primary: PhotoReference?) {
        isExtendingSelection = true
        selectedPhotos = primary == nil ? [] : selection
        selectedPhoto = primary
        isExtendingSelection = false
    }

    /// The selected photo closest to `photo`, preferring the ones after it.
    private func nearest(to photo: PhotoReference, among selection: Set<PhotoReference>,
                         in photos: [ListedPhoto]) -> PhotoReference? {
        guard let index = photos.firstIndex(where: { $0.id == photo }) else {
            return photos.first { selection.contains($0.id) }?.id
        }
        return photos[index...].first { selection.contains($0.id) }?.id
            ?? photos[..<index].last { selection.contains($0.id) }?.id
    }

    /// Enters Edit for the selected photo. Without a selection it stays in Browse.
    public mutating func edit() {
        if selectedPhoto != nil { mode = .editing }
    }

    /// Returns to Browse with the same photo selected.
    public mutating func finishEditing() {
        mode = .browsing
    }

    /// Switches between the edited photo and the original. Only in Edit.
    public mutating func toggleOriginal() {
        isShowingOriginal = mode == .editing && !isShowingOriginal
    }

    /// Shows the edited photo again, as after a change to the edit.
    public mutating func showEdited() {
        isShowingOriginal = false
    }

    /// Keeps the selection valid after the shown photos or the filter change. A photo that is
    /// no longer shown is deselected. If that was the photo Edit shows, the first photo still
    /// selected takes its place.
    public mutating func keep(only photos: [ListedPhoto]) {
        let shown = Set(photos.map(\.id))
        let selection = selectedPhotos.intersection(shown)
        guard selection != selectedPhotos else { return }
        let primary = selectedPhoto.flatMap { selection.contains($0) ? $0 : nil }
            ?? photos.first { selection.contains($0.id) }?.id
        setSelection(selection, primary: primary)
        selectionAtAnchor.formIntersection(shown)
        if let anchor, !shown.contains(anchor) { self.anchor = primary }
    }

    /// The selected photo's position among `photos`, counting from 1, as in "3 of 120".
    public func position(in photos: [ListedPhoto]) -> Int? {
        photos.firstIndex { $0.id == selectedPhoto }.map { $0 + 1 }
    }

    /// Moves the selection in a grid of `photos` laid out in rows of `columns`, from the photo Edit
    /// shows, and selects only the photo it lands on. With nothing selected, any move selects the
    /// first photo. A move past the edge of the grid does nothing.
    public mutating func move(_ move: Move, in photos: [ListedPhoto], columns: Int) {
        guard !photos.isEmpty else { return }
        guard let current = photos.firstIndex(where: { $0.id == selectedPhoto }) else {
            selectedPhoto = photos[0].id
            return
        }
        let columns = max(columns, 1)
        let target = switch move {
        case .left: current % columns == 0 ? current : current - 1
        case .right: current % columns == columns - 1 ? current : current + 1
        case .up: current - columns
        case .down: current + columns
        }
        if photos.indices.contains(target) { selectedPhoto = photos[target].id }
    }
}
