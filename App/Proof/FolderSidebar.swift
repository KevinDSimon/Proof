import ProofKit
import SwiftUI

/// All Photos, then the saved folders and their subfolders, exactly as they are on disk.
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
            }
            Section("Folders") {
                ForEach(library.locations) { location in
                    LocationRow(library: library, location: location)
                        .contextMenu {
                            if library.status(of: location.id) == .missing {
                                Button("Locate…") { library.requestFolder(.locate(location)) }
                            }
                            Button("Remove Folder…") { removing = location }
                        }
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
                if !library.locations.isEmpty {
                    Button("Refresh", systemImage: "arrow.clockwise") { library.refresh() }
                        .help("Read the folders again, including folders on network volumes")
                }
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

    var body: some View {
        switch library.status(of: location.id) {
        case .available:
            FolderRow(library: library, folder: FileReference(locationID: location.id, relativePath: []),
                      name: location.name)
        case .offline:
            SidebarLabel(name: location.name)
                .foregroundStyle(.secondary)
                .help("The drive or network volume this folder is on isn't connected.")
                .tag(SidebarItem.folder(FileReference(locationID: location.id, relativePath: [])))
        case .missing:
            HStack {
                SidebarLabel(name: location.name)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Locate…") { library.requestFolder(.locate(location)) }
                    .controlSize(.small)
            }
            .help("Proof can't find this folder. It was last at \(location.lastKnownURL.path).")
            .tag(SidebarItem.folder(FileReference(locationID: location.id, relativePath: [])))
        }
    }
}

/// A folder with its photo count. Its subfolders are read when it first appears,
/// so the disclosure triangle shows only for folders that have subfolders.
private struct FolderRow: View {
    let library: Library
    let folder: FileReference
    let name: String
    @State private var isExpanded = false

    var body: some View {
        Group {
            if let contents = library.contents[folder], !contents.subfolders.isEmpty {
                DisclosureGroup(isExpanded: $isExpanded) {
                    ForEach(contents.subfolders, id: \.self) { subfolder in
                        FolderRow(library: library,
                                  folder: FileReference(locationID: folder.locationID,
                                                        relativePath: folder.relativePath + [subfolder]),
                                  name: subfolder)
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
    }
}

/// A row's name with a gray symbol instead of the accent-colored one a sidebar gives it, so the
/// sidebar stays neutral.
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
