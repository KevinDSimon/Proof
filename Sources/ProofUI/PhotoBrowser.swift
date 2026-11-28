import ProofKit
import SwiftUI

/// The selected row's photos as a grid, or why there are none: no folders, a folder that is
/// missing or offline, or a filter nothing passes. Shared by the Mac window's detail and the iOS
/// app's grid column.
public struct PhotoBrowser: View {
    let library: Library

    public init(library: Library) {
        self.library = library
    }

    public var body: some View {
        if library.locations.isEmpty {
            ContentUnavailableView {
                Label("No Folders", systemImage: "folder")
            } description: {
                Text("Add a folder of photos to browse and edit them.")
            } actions: {
                // Gray and white, as Add Looks is in the Looks card and sheet (#320).
                Button("Add Folder…") { library.requestFolder(.add) }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
        } else if library.selection?.isAcrossFolders == true {
            allPhotos
        } else if let selection = library.selection?.folder, let location = selectedLocation {
            switch library.status(of: selection.locationID) {
            case .missing:
                ContentUnavailableView {
                    Label("Folder Not Found", systemImage: "questionmark.folder")
                } description: {
                    Text("“\(location.name)” was moved or deleted. Locate it to see its photos again.")
                } actions: {
                    Button("Locate…") { library.requestFolder(.locate(location)) }
                        .buttonStyle(.bordered)
                        .tint(.white)
                }
            case .offline:
                ContentUnavailableView("Drive Not Connected", systemImage: "externaldrive.badge.xmark",
                                       description: Text("Connect the drive or network volume that holds “\(location.name)”."))
            case .available:
                if library.contents[selection] != nil {
                    // Subfolders come first, as tiles, so a folder of only subfolders shows them.
                    let subfolders = library.subfolders(of: selection)
                    if library.visiblePhotos.isEmpty && subfolders.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "photo",
                                               description: Text(library.filter.isEmpty ? "There are no photos to show in this folder."
                                                                                        : "No photos in this folder match the filter."))
                    } else {
                        ThumbnailGrid(library: library, photos: library.shownPhotos, allPhotos: library.listedPhotos,
                                      folders: subfolders)
                    }
                } else {
                    // Rows read their folders as they appear, so a remembered subfolder inside a
                    // collapsed folder is read here.
                    ProgressView()
                        .task(id: selection) { await library.load(selection) }
                }
            }
        } else {
            ContentUnavailableView("No Folder Selected", systemImage: "sidebar.left",
                                   description: Text("Select a folder in the sidebar to see its photos."))
        }
    }

    /// Photos from every available location. Locations that can't be reached are left out, and
    /// the subtitle names them.
    @ViewBuilder private var allPhotos: some View {
        if library.unavailableLocations.count == library.locations.count {
            ContentUnavailableView("No Folders Available", systemImage: "externaldrive.badge.xmark",
                                   description: Text("Connect the drives or network volumes that hold your folders."))
        } else if !library.visiblePhotos.isEmpty {
            ThumbnailGrid(library: library, photos: library.shownPhotos, allPhotos: library.listedPhotos)
        } else if library.isReadingAllPhotos {
            ProgressView()
        } else {
            ContentUnavailableView(emptyTitle, systemImage: "photo",
                                   description: Text(library.activeFilter.isEmpty ? "There are no photos to show in your folders."
                                                                                  : "No photos in your folders match."))
        }
    }

    private var selectedLocation: SavedLocation? {
        library.locations.first { $0.id == library.selection?.folder?.locationID }
    }

    private var emptyTitle: String {
        if let row = library.selection?.filter, library.filter.isEmpty {
            return "No \(row.rating.map { "\($0)-Star" } ?? row.title) Photos"
        }
        return library.filter.isEmpty ? "No Photos" : "No Matching Photos"
    }
}

/// The filter's toolbar button, in Browse and in Edit. Both change the same filter, so
/// filtering in either mode narrows the grid and the filmstrip (#160).
public struct FilterButton: View {
    let library: Library

    public init(library: Library) {
        self.library = library
    }

    public var body: some View {
        Menu {
            FilterMenu(library: library)
        } label: {
            // While a filter is on, the button shows how many parts are set, so it reads as
            // on without an accent color. The tooltip names them. The symbol has no circle
            // around it, so it is as large as the other toolbar symbols.
            if library.filter.isEmpty {
                Label("Filter", systemImage: "line.3.horizontal.decrease")
            } else {
                Label("\(library.filter.activeCount)", systemImage: "line.3.horizontal.decrease")
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
            }
        }
        .menuIndicator(.hidden)
        .help(library.filter.isEmpty ? "Show only some of the photos" : "Filtered by \(library.filter.summary)")
        .accessibilityLabel(library.filter.isEmpty ? "Filter" : "Filter: \(library.filter.summary)")
    }
}

public extension Library {
    /// The window's title: the selected row in Browse, the photo's name in Edit.
    var windowTitle: String {
        if isEditing { return browse.selectedPhoto?.name ?? "" }
        return rowTitle
    }

    /// The selected sidebar row's name, in Browse and in Edit.
    var rowTitle: String {
        selection.map(title(of:)) ?? ""
    }

    /// A sidebar row's name.
    func title(of item: SidebarItem) -> String {
        switch item {
        case .allPhotos: return "All Photos"
        case .filtered(let filter): return filter.title
        case .folder(let folder): return name(of: folder)
        }
    }

    /// In Browse, how many photos are shown, and for All Photos which locations are left out; in
    /// Edit, the photo's folder and its position, after "Original" while backslash shows it.
    var windowSubtitle: String {
        let visible = visiblePhotos
        if isEditing {
            let position = browse.position(in: visible).map { "\($0) of \(visible.count)" }
            // A saved location that is a single photo has no folder name to show.
            let folder = browse.selectedPhoto.map { name(of: $0.folder) }
            let shownFolder = folder == browse.selectedPhoto?.name ? nil : folder
            let original = browse.isShowingOriginal ? "Original" : nil
            return [original, shownFolder, position, selectedCount].compactMap { $0 }.joined(separator: " · ")
        }
        if let folder = selection?.folder, contents[folder] == nil { return "" }
        if selection == nil { return "" }
        let total = listedPhotos.count
        let noun = total == 1 ? "photo" : "photos"
        let shown = if selection?.filter != nil {
            "\(visible.count) \(visible.count == 1 ? "photo" : "photos")"
        } else if !filter.isEmpty {
            "\(visible.count) of \(total) \(noun)"
        } else {
            "\(total) \(noun)"
        }
        let count = [shown, selectedCount].compactMap { $0 }.joined(separator: " · ")
        let unavailable = unavailableLocations
        guard selection?.isAcrossFolders == true, !unavailable.isEmpty else { return count }
        let missing = unavailable.count == 1 ? "“\(unavailable[0].name)” isn't available"
                                             : "\(unavailable.count) folders aren't available"
        return "\(count) · \(missing)"
    }

    /// "3 selected", while more than one photo is. While Select is on, the iOS title counts them.
    private var selectedCount: String? {
        browse.hasMultipleSelection && !isSelectingPhotos ? "\(browse.selectedPhotos.count) selected" : nil
    }

}
