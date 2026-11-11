import Foundation

/// Whether the window is browsing photos or editing one of them, and which photo is selected.
/// Photos are identified by folder and file name, since All Photos shows several folders at once.
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
    /// Clearing the selection also leaves Edit, since there is no photo left to edit.
    public var selectedPhoto: PhotoReference? {
        didSet {
            if selectedPhoto == nil { mode = .browsing }
            if selectedPhoto != oldValue { isShowingOriginal = false }
        }
    }
    /// In Edit, the photo is shown without its edit, to compare. Leaving the photo or Edit ends it.
    public private(set) var isShowingOriginal = false

    public init(selectedPhoto: PhotoReference? = nil) {
        self.selectedPhoto = selectedPhoto
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
    /// no longer shown is deselected.
    public mutating func keep(only photos: [ListedPhoto]) {
        if let selectedPhoto, !photos.contains(where: { $0.id == selectedPhoto }) {
            self.selectedPhoto = nil
        }
    }

    /// The selected photo's position among `photos`, counting from 1, as in "3 of 120".
    public func position(in photos: [ListedPhoto]) -> Int? {
        photos.firstIndex { $0.id == selectedPhoto }.map { $0 + 1 }
    }

    /// Moves the selection in a grid of `photos` laid out in rows of `columns`. With nothing
    /// selected, any move selects the first photo. A move past the edge of the grid does nothing.
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
