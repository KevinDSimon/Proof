import ProofKit
import ProofUI
import SwiftUI

/// The saved folders, as they are in Files. All Photos, filters and subfolders join them with the
/// shared sidebar (#224).
struct FolderList: View {
    @Bindable var library: Library
    @State private var removing: SavedLocation?

    var body: some View {
        List(selection: $library.selection) {
            if !library.locations.isEmpty {
                Section("Folders") {
                    ForEach(library.locations) { location in
                        LocationRow(library: library, location: location) { removing = $0 }
                    }
                }
            }
        }
        // Each saved folder and the folders already read in it are read again, as on returning
        // to Proof. A drive that was plugged in or unplugged since is found here too.
        .refreshable { library.refresh() }
        .confirmationDialog("Remove “\(removing?.name ?? "")” from Proof?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible,
                            presenting: removing) { location in
            Button("Remove", role: .destructive) { library.remove(location) }
        } message: { _ in
            Text("The photos and edits in this folder are not deleted. You can add it again later.")
        }
    }
}

/// A saved folder with its photo count. When it can't be reached it is dimmed, says why, and
/// offers what can be done.
private struct LocationRow: View {
    let library: Library
    let location: SavedLocation
    let remove: (SavedLocation) -> Void

    var body: some View {
        let root = FileReference(locationID: location.id, relativePath: [])
        let status = library.status(of: location.id)
        row(status)
            .tag(SidebarItem.folder(root))
            .swipeActions {
                Button("Remove", systemImage: "minus.circle", role: .destructive) { remove(location) }
            }
            .contextMenu {
                if case .missing = status {
                    Button("Locate…", systemImage: "magnifyingglass") { library.requestFolder(.locate(location)) }
                }
                Button("Refresh", systemImage: "arrow.clockwise") { library.refresh(root) }
                    .disabled(library.url(of: root) == nil)
                Divider()
                Button("Remove Folder…", systemImage: "minus.circle", role: .destructive) { remove(location) }
            }
    }

    @ViewBuilder private func row(_ status: LocationStatus) -> some View {
        let root = FileReference(locationID: location.id, relativePath: [])
        switch status {
        case .available:
            Label {
                Text(location.name)
            } icon: {
                // Gray, as on the Mac: the highlight color is only for marks of state.
                Image(systemName: "folder").foregroundStyle(.secondary)
            }
            .badge(library.contents[root]?.photos.count ?? 0)
            .task { await library.load(root) }
        case .offline:
            Label {
                VStack(alignment: .leading) {
                    Text(location.name)
                    Text("Not connected").font(.caption)
                }
            } icon: {
                Image(systemName: "externaldrive.badge.xmark")
            }
            .foregroundStyle(.secondary)
            .accessibilityHint("The drive or server this folder is on isn't connected.")
        case .missing:
            HStack {
                Label(location.name, systemImage: "questionmark.folder")
                    .foregroundStyle(.secondary)
                Spacer()
                // Borderless, so it reads as a link and takes its own tap instead of selecting the row.
                Button("Locate…") { library.requestFolder(.locate(location)) }
                    .buttonStyle(.borderless)
            }
            .accessibilityHint("Proof can't find this folder. It was last at \(location.lastKnownURL.path).")
        }
    }
}
