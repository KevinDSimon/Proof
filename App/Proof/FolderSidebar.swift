import ProofKit
import SwiftUI

/// Saved folders and their subfolders, exactly as they are on disk.
struct FolderSidebar: View {
    @Bindable var library: Library
    @State private var removing: SavedLocation?

    var body: some View {
        List(selection: $library.selection) {
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
        .onDeleteCommand {
            removing = library.locations.first {
                library.selection == FileReference(locationID: $0.id, relativePath: [])
            }
        }
        .toolbar {
            Button("Add Folder", systemImage: "folder.badge.plus") { library.requestFolder(.add) }
                .help("Add a folder of RAW photos")
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
            Label(location.name, systemImage: "folder")
                .foregroundStyle(.secondary)
                .help("The drive or network volume this folder is on isn't connected.")
                .tag(FileReference(locationID: location.id, relativePath: []))
        case .missing:
            HStack {
                Label(location.name, systemImage: "folder")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Locate…") { library.requestFolder(.locate(location)) }
                    .controlSize(.small)
            }
            .help("Proof can't find this folder. It was last at \(location.lastKnownURL.path).")
            .tag(FileReference(locationID: location.id, relativePath: []))
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
        Label(name, systemImage: "folder")
            .badge(library.contents[folder]?.photos.count ?? 0)
            .tag(folder)
    }
}
