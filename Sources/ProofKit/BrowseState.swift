import Foundation

/// Whether the window is browsing a folder or editing one of its photos, and which photo is
/// selected. Photos are identified by file name within the selected folder.
public struct BrowseState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case browsing
        case editing
    }

    public enum Move: Sendable {
        case left, right, up, down
    }

    public private(set) var mode: Mode = .browsing
    /// Clearing the selection also leaves Edit, since there is no photo left to edit.
    public var selectedPhoto: String? {
        didSet { if selectedPhoto == nil { mode = .browsing } }
    }

    public init(selectedPhoto: String? = nil) {
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

    /// Keeps the selection valid after the folder's photos or the filter change. A photo that is
    /// no longer shown is deselected.
    public mutating func keep(only photos: [FolderContents.Photo]) {
        if let selectedPhoto, !photos.contains(where: { $0.name == selectedPhoto }) {
            self.selectedPhoto = nil
        }
    }

    /// The selected photo's position among `photos`, counting from 1, as in "3 of 120".
    public func position(in photos: [FolderContents.Photo]) -> Int? {
        photos.firstIndex { $0.name == selectedPhoto }.map { $0 + 1 }
    }

    /// Moves the selection in a grid of `photos` laid out in rows of `columns`. With nothing
    /// selected, any move selects the first photo. A move past the edge of the grid does nothing.
    public mutating func move(_ move: Move, in photos: [FolderContents.Photo], columns: Int) {
        guard !photos.isEmpty else { return }
        guard let current = photos.firstIndex(where: { $0.name == selectedPhoto }) else {
            selectedPhoto = photos[0].name
            return
        }
        let columns = max(columns, 1)
        let target = switch move {
        case .left: current % columns == 0 ? current : current - 1
        case .right: current % columns == columns - 1 ? current : current + 1
        case .up: current - columns
        case .down: current + columns
        }
        if photos.indices.contains(target) { selectedPhoto = photos[target].name }
    }
}
