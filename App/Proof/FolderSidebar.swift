import ProofKit
import SwiftUI

/// All Photos and the filter rows, then the saved folders and their subfolders, exactly as they are on disk.
struct FolderSidebar: View {
    @Bindable var library: Library
    @State private var removing: SavedLocation?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        List(selection: $library.selection) {
            if !library.locations.isEmpty {
                SidebarLabel(name: "All Photos", systemImage: "photo.on.rectangle")
                    .help("Photos from every saved folder and its subfolders")
                    .tag(SidebarItem.allPhotos)
                let counts = library.filterCounts
                ForEach(PhotoFilter.choices, id: \.self) { filter in
                    FilterLabel(filter: filter, count: counts[filter] ?? 0)
                        .tag(SidebarItem.filtered(filter))
                }
            }
            Section("Folders") {
                ForEach(library.locations) { location in
                    LocationRow(library: library, location: location) { removing = $0 }
                }
            }
        }
        // The same plain color as the grid and the photo's canvas, instead of the sidebar material,
        // so the window reads as one surface.
        .scrollContentBackground(.hidden)
        .background(Color(white: PhotoCanvas.backdropGray(for: colorScheme)).ignoresSafeArea())
        .onDeleteCommand {
            removing = library.locations.first {
                library.selection == .folder(FileReference(locationID: $0.id, relativePath: []))
            }
        }
        .toolbar {
            // The sidebar is hidden while editing, and so is its button.
            if !library.isEditing {
                Button("Add Folder", systemImage: "folder.badge.plus") { library.requestFolder(.add) }
                    .help("Add a folder of RAW photos")
            }
        }
        .confirmationDialog("Remove “\(removing?.name ?? "")” from Proof?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { location in
            Button("Remove", role: .destructive) { library.remove(location) }
        } message: { _ in
            Text("The photos and edits in this folder are not deleted. You can add it again later.")
        }
    }
}

/// A saved folder. When it can't be reached it is dimmed and doesn't expand.
private struct LocationRow: View {
    let library: Library
    let location: SavedLocation
    let remove: (SavedLocation) -> Void

    var body: some View {
        let root = FileReference(locationID: location.id, relativePath: [])
        switch library.status(of: location.id) {
        case .available:
            FolderRow(library: library, folder: root, name: location.name, remove: remove)
        case .offline:
            SidebarLabel(name: location.name)
                .foregroundStyle(.secondary)
                .help("The drive or network volume this folder is on isn't connected.")
                .tag(SidebarItem.folder(root))
                .contextMenu { FolderContextMenu(library: library, folder: root, remove: remove) }
        case .missing:
            HStack {
                SidebarLabel(name: location.name)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Locate…") { library.requestFolder(.locate(location)) }
                    .controlSize(.small)
            }
            .help("Proof can't find this folder. It was last at \(location.lastKnownURL.path).")
            .tag(SidebarItem.folder(root))
            .contextMenu { FolderContextMenu(library: library, folder: root, remove: remove) }
        }
    }
}

/// A folder with its photo count. Its subfolders are read when it first appears,
/// so the disclosure triangle shows only for folders that have subfolders.
private struct FolderRow: View {
    let library: Library
    let folder: FileReference
    let name: String
    let remove: (SavedLocation) -> Void
    @State private var isExpanded = false

    var body: some View {
        Group {
            if let contents = library.contents[folder], !contents.subfolders.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(contents.subfolders, id: \.self) { subfolder in
                        FolderRow(library: library,
                                  folder: FileReference(locationID: folder.locationID,
                                                        relativePath: folder.relativePath + [subfolder]),
                                  name: subfolder, remove: remove)
                    }
                } label: {
                    label
                }
            } else {
                label
            }
        }
        .task { await library.load(folder) }
    }

    private var label: some View {
        SidebarLabel(name: name, count: library.contents[folder]?.photos.count ?? 0)
            .tag(SidebarItem.folder(folder))
            .contextMenu { FolderContextMenu(library: library, folder: folder, remove: remove) }
    }
}

/// The right-click menu of a folder in the sidebar. Remove Folder… and Locate… are for saved
/// folders only, since subfolders are part of the saved folder they're in.
private struct FolderContextMenu: View {
    let library: Library
    let folder: FileReference
    let remove: (SavedLocation) -> Void

    var body: some View {
        let url = library.url(of: folder)
        Button("Show in Finder") { if let url { library.showInFinder([url]) } }
            .disabled(url == nil)
        Button("Copy Path") { if let url { library.copyPaths([url]) } }
            .disabled(url == nil)
        Button("Refresh") { library.refresh(folder) }
            .disabled(url == nil)
        if folder.relativePath.isEmpty, let location = library.locations.first(where: { $0.id == folder.locationID }) {
            Divider()
            if library.status(of: location.id) == .missing {
                Button("Locate…") { library.requestFolder(.locate(location)) }
            }
            Button("Remove Folder…") { remove(location) }
        }
    }
}

/// A row's name with a gray symbol instead of the accent-colored one a sidebar gives it, so the
/// sidebar stays neutral.
/// A filter row: its symbol and name, with stars drawn as star glyphs, and how many photos match,
/// zero included.
private struct FilterLabel: View {
    let filter: PhotoFilter
    let count: Int
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Label {
            if let rating = filter.rating {
                HStack(spacing: 1) {
                    ForEach(0..<rating, id: \.self) { _ in Image(systemName: "star.fill") }
                }
                .imageScale(.small)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(filter.title)
            } else {
                Text(filter.title)
            }
        } icon: {
            Image(systemName: Self.symbol(for: filter))
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.foreground) : AnyShapeStyle(.secondary))
        }
        .badge(Text(count, format: .number))
        .help(help)
    }

    private var help: String {
        switch filter {
        case .flagged: "Flagged photos from every saved folder"
        case .rejected: "Rejected photos from every saved folder"
        case .edited: "Edited photos from every saved folder"
        default: "Photos rated exactly \(filter.title.lowercased()) from every saved folder, except rejected ones"
        }
    }

    static func symbol(for filter: PhotoFilter) -> String {
        switch filter {
        case .all: "photo.on.rectangle"
        case .flagged: "flag"
        case .rejected: "flag.slash"
        case .edited: "slider.horizontal.3"
        default: "star"
        }
    }
}

private struct SidebarLabel: View {
    let name: String
    var systemImage = "folder"
    /// The number of photos, shown as the row's badge. Zero shows none.
    var count = 0
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Label {
            Text(name)
        } icon: {
            // In a selected row the symbol takes the row's text color.
            Image(systemName: systemImage)
                .foregroundStyle(prominence == .increased ? AnyShapeStyle(.foreground) : AnyShapeStyle(.secondary))
        }
        .badge(count == 0 ? nil : Text(count, format: .number))
    }
}
