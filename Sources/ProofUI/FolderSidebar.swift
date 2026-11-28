import ProofKit
import SwiftUI

/// All Photos and the filter rows, then the saved folders and their subfolders, exactly as they are on disk.
public struct FolderSidebar: View {
    @Bindable var library: Library
    @State private var removing: SavedLocation?

    public init(library: Library) {
        self.library = library
    }

    public var body: some View {
        List(selection: $library.selection) {
            if !library.locations.isEmpty {
                SidebarLabel(name: "All Photos", systemImage: "photo.on.rectangle")
                    .help("Photos from every saved folder and its subfolders")
                    .tag(SidebarItem.allPhotos)
                let counts = library.filterCounts
                ForEach(PhotoFilter.allCases, id: \.self) { filter in
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
        .background(Color.interfaceBackground.ignoresSafeArea())
        #if os(iOS)
        // iOS has no FSEvents, so each saved folder and the folders already read in it are read
        // again here, as on returning to Proof. A drive plugged in or unplugged since is found too.
        .refreshable { library.refresh() }
        #endif
        #if os(macOS)
        .onDeleteCommand {
            removing = library.locations.first {
                library.selection == .folder(FileReference(locationID: $0.id, relativePath: []))
            }
        }
        #endif
        .toolbar {
            // The sidebar is hidden while editing, and so is its button.
            if !library.isEditing {
                Button("Add Folder", systemImage: "folder.badge.plus") { library.requestFolder(.add) }
                    .help("Add a folder of photos")
            }
        }
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

/// A saved folder. When it can't be reached it is dimmed and doesn't expand.
private struct LocationRow: View {
    let library: Library
    let location: SavedLocation
    let remove: (SavedLocation) -> Void
    @Environment(\.foldersFollowFiles) private var foldersFollowFiles

    var body: some View {
        row
            #if os(iOS)
            .swipeActions {
                Button("Remove", systemImage: "minus.circle", role: .destructive) { remove(location) }
            }
            #endif
    }

    @ViewBuilder private var row: some View {
        let root = FileReference(locationID: location.id, relativePath: [])
        switch library.status(of: location.id) {
        case .available:
            FolderRow(library: library, folder: root, name: location.name, remove: remove)
        case .offline:
            folderLabel(location.name)
                .foregroundStyle(.secondary)
                .help("The drive or network volume this folder is on isn't connected.")
                .tag(SidebarItem.folder(root))
                .contextMenu { FolderContextMenu(library: library, folder: root, remove: remove) }
        case .missing:
            HStack {
                folderLabel(location.name)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { library.requestFolder(.locate(location)) } label: {
                    Text("Locate…").minimumTouchTarget()
                }
                    .controlSize(.small)
                    #if os(iOS)
                    // Reads as a link and takes its own tap instead of selecting the row.
                    .buttonStyle(.borderless)
                    #endif
            }
            .help("Proof can't find this folder. It was last at \(location.lastKnownURL.path).")
            .tag(SidebarItem.folder(root))
            .contextMenu { FolderContextMenu(library: library, folder: root, remove: remove) }
        }
    }
}

extension LocationRow {
    /// A saved folder that can't be reached, lined up with the others on iPhone.
    @ViewBuilder func folderLabel(_ name: String) -> some View {
        if foldersFollowFiles {
            PhoneFolderLabel(name: name, isDimmed: true) { DisclosureArrow.placeholder }
        } else {
            SidebarLabel(name: name, isDimmed: true)
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
    @State private var hasExpandedFirst = false
    /// How far each level of subfolders is indented on iPhone: about one icon column.
    @ScaledMetric private var indent: CGFloat = 40
    /// Set on iPhone (#313). There the tree starts expanded, so subfolders are seen without
    /// finding the disclosure arrow.
    @Environment(\.foldersFollowFiles) private var foldersFollowFiles

    var body: some View {
        Group {
            if foldersFollowFiles {
                phoneRows
            } else if let contents = library.contents[folder], !contents.subfolders.isEmpty {
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
                #if os(iOS)
                // iOS reads the selection tag from the row, not from the disclosure's label.
                .tag(SidebarItem.folder(folder))
                #endif
            } else {
                label
            }
        }
        .task { await library.load(folder) }
        .onAppear {
            if foldersFollowFiles, !hasExpandedFirst {
                hasExpandedFirst = true
                isExpanded = true
            }
            revealSelection()
        }
        // A subfolder opened from the grid's tiles is selected; its folder expands so its row shows.
        .onChange(of: library.selection) { revealSelection() }
    }

    private func revealSelection() {
        if let selected = library.selection?.folder, selected != folder, folder.contains(selected) {
            isExpanded = true
        }
    }

    private var label: some View {
        SidebarLabel(name: name, count: library.contents[folder]?.photos.count ?? 0)
            .tag(SidebarItem.folder(folder))
            .contextMenu { FolderContextMenu(library: library, folder: folder, remove: remove) }
    }

    /// iPhone's rows, as in Files: the disclosure arrow leads the row, in the icon column the rows
    /// above use, and the folder's symbol sits where their names start. A folder without
    /// subfolders leaves the arrow's place empty, so every row lines up, and each level is
    /// indented by one column. `DisclosureGroup` puts the arrow at the trailing end on iPhone,
    /// where it reads as the arrow that opens the row.
    @ViewBuilder private var phoneRows: some View {
        let subfolders = library.subfolders(of: folder)
        PhoneFolderLabel(name: name, count: library.contents[folder]?.photos.count ?? 0) {
            if subfolders.isEmpty {
                DisclosureArrow.placeholder
            } else {
                Button {
                    withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
                } label: {
                    DisclosureArrow(isExpanded: isExpanded)
                        // A 44-point target around the arrow.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                        .padding(-12)
                }
                // Takes its own tap instead of selecting the row.
                .buttonStyle(.borderless)
                .accessibilityLabel(isExpanded ? "Collapse \(name)" : "Expand \(name)")
            }
        }
        .padding(.leading, CGFloat(folder.relativePath.count) * indent)
        .tag(SidebarItem.folder(folder))
        .contextMenu { FolderContextMenu(library: library, folder: folder, remove: remove) }
        if isExpanded {
            ForEach(subfolders, id: \.self) { subfolder in
                FolderRow(library: library, folder: subfolder, name: library.name(of: subfolder), remove: remove)
            }
        }
    }
}

/// The disclosure arrow that leads a folder row on iPhone (#313), gray rather than the button's
/// tint, since the highlight is for marks of state only.
private struct DisclosureArrow: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color.secondary)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
    }

    /// The arrow's place in a row that can't expand, kept so the row lines up with the others.
    static var placeholder: some View {
        DisclosureArrow(isExpanded: false).hidden().accessibilityHidden(true)
    }
}

/// A folder row's label on iPhone: `disclosure` in the label's icon column, so it lines up with
/// the icons of All Photos and the filter rows, then the folder symbol and name in the title,
/// so the symbol lines up with their names.
private struct PhoneFolderLabel<Disclosure: View>: View {
    let name: String
    var count = 0
    var isDimmed = false
    @ViewBuilder let disclosure: Disclosure

    var body: some View {
        Label {
            HStack(spacing: 10) {
                FolderIcon(isDimmed: isDimmed)
                Text(name)
            }
        } icon: {
            disclosure
        }
        .badge(count == 0 ? nil : Text(count, format: .number))
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
        #if os(macOS)
        Button("Show in Finder") { if let url { library.showInFinder([url]) } }
            .disabled(url == nil)
        #endif
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
        case .flagged: "flag"
        case .rejected: "flag.slash"
        case .edited: "slider.horizontal.3"
        default: "star"
        }
    }
}

private struct SidebarLabel: View {
    let name: String
    /// A symbol, or none for a folder, which shows the manila folder.
    var systemImage: String?
    /// The number of photos, shown as the row's badge. Zero shows none.
    var count = 0
    var isDimmed = false
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Label {
            Text(name)
        } icon: {
            if let systemImage {
                // In a selected row the symbol takes the row's text color.
                Image(systemName: systemImage)
                    .foregroundStyle(prominence == .increased ? AnyShapeStyle(.foreground) : AnyShapeStyle(.secondary))
            } else {
                FolderIcon(isDimmed: isDimmed)
            }
        }
        .badge(count == 0 ? nil : Text(count, format: .number))
    }
}
