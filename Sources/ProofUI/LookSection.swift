import ProofKit
import SwiftUI
import UniformTypeIdentifiers

/// The Looks section of the inspector: the strength of the chosen look, a pop-up of the library's
/// folders, and the shown folder's LUTs as a grid of small previews of the photo through each.
/// The arrow keys move through the grid, choosing as they go. The pop-up also adds `.cube` files
/// and folders, from an Open panel on the Mac and the Files picker on iPad and iPhone, and on the
/// Mac opens the library in the Finder; files can be dropped on the grid too. On iPad and iPhone,
/// where Files doesn't show the library, a tile's touch-and-hold menu and the pop-up rename and
/// remove looks and folders instead. Reset removes the look, so there is no None row. The iPhone's Looks sheet shows the same controls without the
/// card, since the sheet has the title and no switch (decision 0054).
public struct LookSection: View {
    let library: Library
    let isCard: Bool
    @State private var isImporting = false
    /// The look or folder being renamed or about to be removed, and the name typed for it.
    @State private var renaming: LibraryItem?
    @State private var newName = ""
    @State private var removing: LibraryItem?
    @State private var changeError: String?
    @FocusState private var isGridFocused: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private static let cubeType = UTType(filenameExtension: LUTLibrary.fileExtension, conformingTo: .data) ?? .data

    public init(library: Library, isCard: Bool = true) {
        self.library = library
        self.isCard = isCard
    }

    public var body: some View {
        Group {
            if isCard {
                InspectorCard(title: "Looks", isOn: library.isOnBinding(.look), canReset: look != nil,
                              reset: { library.changeEdit { $0.look = nil } }) {
                    controls
                }
            } else {
                VStack(alignment: .leading, spacing: 12) { controls }
            }
        }
        .disabled(library.selectedEdit == nil)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [Self.cubeType, .folder],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importItems(urls)
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .modifier(ManageItems(renaming: $renaming, newName: $newName, removing: $removing, changeError: $changeError,
                              rename: rename, remove: remove))
        .onAppear {
            looks.reload()
            showChosenLook()
        }
        .onChange(of: look?.lut) { showChosenLook() }
        .task(id: previewKey) {
            guard let previewKey else { return }
            looks.makePreviews(of: previewKey.url, recipe: previewKey.recipe)
        }
    }

    @ViewBuilder private var controls: some View {
        if looks.names.isEmpty {
            // One line of description, so the empty card isn't much taller than the others.
            ContentUnavailableView {
                Label("No Looks", systemImage: "camera.filters")
            } description: {
                Text(Self.emptyDescription)
            } actions: {
                Button("Add Looks…") { isImporting = true }
                    .emptyStateAction()
            }
            .dropDestination(for: URL.self) { urls, _ in
                importItems(urls)
                return true
            }
        } else {
            // First, so choosing a look or another folder never moves it.
            AdjustmentSlider(
                title: "Strength",
                value: Binding(get: { (look?.strength ?? 1) * 100 },
                               set: { value in
                                   // The iPhone's sheet has no switch, so a switched-off look comes back on.
                                   if !library.isOn(.look) { library.setOn(.look, true) }
                                   library.changeEdit { $0.look?.strength = value / 100 }
                               }),
                range: 0...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                unit: "percent",
                reset: { library.changeEdit { $0.look?.strength = 1 } },
                isAdjusting: { library.isAdjusting = $0 })
                .disabled(look == nil)
            if let look, !looks.names.contains(look.lut) {
                Text("“\(Self.title(of: look.lut))” isn’t in the LUT library, so the photo is shown without it.")
                    .foregroundStyle(.secondary)
            }
            folderMenu
            grid
        }
    }

    /// The folder pop-up, titled with the chosen look, or with the shown folder when no look in
    /// it is chosen. A folder that holds other folders opens as a submenu.
    private var folderMenu: some View {
        PopUpMenu(title: menuTitle, items: folderItems(under: "") + [.separator] + libraryItems)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Looks folder")
    }

    /// The library's own files are only in the Finder: on iPad and iPhone they're in Proof's
    /// container, which Files doesn't show.
    private var libraryItems: [PopUpMenu.Item] {
        #if os(macOS)
        [.action("Add Looks…") { isImporting = true },
         .action("Reveal in Finder") { looks.revealInFinder() }]
        #else
        var items: [PopUpMenu.Item] = [.action("Add Looks…") { isImporting = true }]
        if !looks.shownFolder.isEmpty {
            let folder = LibraryItem(path: looks.shownFolder, isFolder: true)
            items += [.separator,
                      .action("Rename “\(folder.title)”…") { startRenaming(folder) },
                      .action("Remove “\(folder.title)”…") { removing = folder }]
        }
        return items
        #endif
    }

    #if os(macOS)
    private static let emptyDescription = "Drag .cube files or folders here."
    #else
    private static let emptyDescription = "Add .cube files or folders from Files."
    #endif

    private var menuTitle: String {
        if let look, looks.shownNames.contains(look.lut) { return Self.title(of: look.lut) }
        return Self.folderTitle(looks.shownFolder)
    }

    /// Menu items for the folders directly below `parent`, and for `parent` itself when it holds
    /// LUTs and has subfolders. LUTs outside any folder come last, as Ungrouped.
    private func folderItems(under parent: String) -> [PopUpMenu.Item] {
        let folders = looks.folders
        let children = LUTLibrary.childFolders(of: parent, in: folders)
        var items: [PopUpMenu.Item] = children.map { child in
            let grandchildren = folderItems(under: child)
            guard !grandchildren.isEmpty else { return folderItem(child) }
            return .submenu(Self.folderTitle(child),
                            folders.contains(child) ? [folderItem(child), .separator] + grandchildren : grandchildren)
        }
        if parent.isEmpty, folders.contains("") {
            if !items.isEmpty { items.append(.separator) }
            items.append(folderItem(""))
        }
        return items
    }

    /// A menu item that shows `folder`, checked while it is shown.
    private func folderItem(_ folder: String) -> PopUpMenu.Item {
        .action(Self.folderTitle(folder), isChecked: looks.shownFolder == folder) { looks.shownFolder = folder }
    }

    /// The shown folder's LUTs as a grid of previews of the whole photo. The chosen one has the
    /// filmstrip's outline, and its name is the pop-up's title; each tile's name is under its preview.
    /// With the grid focused, the arrow keys move between tiles and choose as they go.
    private var grid: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.tileSpacing), count: Self.columns),
                      spacing: Self.tileSpacing) {
                ForEach(looks.shownNames, id: \.self) { path in
                    tile(path)
                }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($isGridFocused)
            .onKeyPress(.rightArrow) { step(by: 1) }
            .onKeyPress(.leftArrow) { step(by: -1) }
            .onKeyPress(.downArrow) { step(by: Self.columns) }
            .onKeyPress(.upArrow) { step(by: -Self.columns) }
        }
        .dropDestination(for: URL.self) { urls, _ in
            importItems(urls)
            return true
        }
    }

    private func tile(_ path: String) -> some View {
        let isSelected = look?.lut == path
        let item = LibraryItem(path: path, isFolder: false)
        return VStack(spacing: 4) {
            preview(of: path)
            Text(Self.title(of: path))
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                // Styled as the photo grid's names. Space for every line is kept, so a short name
                // doesn't make its tile shorter than its neighbors.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1, reservesSpace: true)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .frame(maxWidth: .infinity)
        }
            .selectionOutline(isSelected, padding: 4)
            .contentShape(Rectangle())
            .onTapGesture {
                isGridFocused = true
                choose(path)
            }
            .accessibilityElement()
            .accessibilityLabel(Self.title(of: path))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { choose(path) }
            #if !os(macOS)
            .contextMenu {
                Button("Rename…", systemImage: "pencil") { startRenaming(item) }
                Button("Remove…", systemImage: "trash", role: .destructive) { removing = item }
            }
            .accessibilityAction(named: "Rename") { startRenaming(item) }
            .accessibilityAction(named: "Remove") { removing = item }
            #endif
    }

    private func startRenaming(_ item: LibraryItem) {
        newName = item.title
        renaming = item
    }

    private func rename(_ item: LibraryItem) {
        let name = newName
        Task { changeError = await looks.rename(item.path, to: name) }
    }

    private func remove(_ item: LibraryItem) {
        Task { changeError = await looks.remove(item.path) }
    }

    /// Chooses the look `offset` tiles from the chosen one, staying put at either end.
    private func step(by offset: Int) -> KeyPress.Result {
        let names = looks.shownNames
        guard !names.isEmpty else { return .ignored }
        guard let current = look.flatMap({ names.firstIndex(of: $0.lut) }) else {
            choose(names[0])
            return .handled
        }
        let index = current + offset
        if names.indices.contains(index) { choose(names[index]) }
        return .handled
    }

    private func preview(of path: String) -> some View {
        Group {
            if let image = looks.previews[path] {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
            } else {
                Rectangle().fill(.quaternary)
                    .aspectRatio(3 / 2, contentMode: .fit)
            }
        }
        .clipShape(.rect(cornerRadius: SelectionOutline.photoCornerRadius))
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    /// Three across: large enough to judge a look at a glance in the inspector's width.
    private static let columns = 3
    private static let tileSpacing: CGFloat = 6

    private var looks: LookBrowser { library.looks }
    private var look: Look? { library.selectedEdit?.recipe.look }

    private func choose(_ path: String) {
        guard path != look?.lut else { return }
        library.setOn(.look, true)
        library.changeEdit { recipe in
            recipe.look = Look(lut: path, strength: recipe.look?.strength ?? 1)
        }
    }

    /// Shows the folder of the chosen look, when it is in the library.
    private func showChosenLook() {
        guard let path = look?.lut, looks.names.contains(path) else { return }
        looks.show(folderOf: path)
    }

    private var previewKey: PreviewKey? {
        guard let url = library.selectedPhotoURL, let recipe = library.selectedEdit?.recipe else { return nil }
        var withoutLook = recipe
        withoutLook.look = nil
        return PreviewKey(url: url, recipe: withoutLook)
    }

    private struct PreviewKey: Equatable {
        var url: URL
        var recipe: EditRecipe
    }

    /// A look or folder in the library, as the rename alert and remove dialog name it.
    struct LibraryItem: Equatable {
        var path: String
        var isFolder: Bool

        var title: String { isFolder ? (path as NSString).lastPathComponent : LookSection.title(of: path) }
    }

    /// The alert that renames a look or folder, the dialog that confirms removing one, and the
    /// alert that says why either failed. They are the section's own, not `Library.errorMessage`,
    /// so on iPhone they show over the Looks sheet.
    private struct ManageItems: ViewModifier {
        @Binding var renaming: LibraryItem?
        @Binding var newName: String
        @Binding var removing: LibraryItem?
        @Binding var changeError: String?
        let rename: (LibraryItem) -> Void
        let remove: (LibraryItem) -> Void

        func body(content: Content) -> some View {
            content
                .alert(renaming?.isFolder == true ? "Rename Folder" : "Rename Look",
                       isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } }),
                       presenting: renaming) { item in
                    TextField("Name", text: $newName)
                    Button("Cancel", role: .cancel) {}
                    Button("Rename") { rename(item) }
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                } message: { item in
                    Text(item.isFolder ? "Photos that use looks in this folder will show them as missing."
                                       : "Photos that use this look will show it as missing.")
                }
                .confirmationDialog(removing.map { "Remove “\($0.title)”?" } ?? "",
                                    isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                    titleVisibility: .visible, presenting: removing) { item in
                    Button(item.isFolder ? "Remove Folder" : "Remove Look", role: .destructive) { remove(item) }
                    Button("Cancel", role: .cancel) {}
                } message: { item in
                    Text(item.isFolder
                         ? "Proof’s copies of the looks in this folder are deleted. The files you added them from aren’t changed. Photos that use them are shown without them."
                         : "Proof’s copy of this look is deleted. The file you added it from isn’t changed. Photos that use it are shown without it.")
                }
                .alert("Couldn’t Change Looks",
                       isPresented: Binding(get: { changeError != nil }, set: { if !$0 { changeError = nil } })) {
                    Button("OK") {}
                } message: {
                    Text(changeError ?? "")
                }
        }
    }

    private func importItems(_ urls: [URL]) {
        Task {
            if let message = await looks.importItems(urls) { library.errorMessage = message }
        }
    }

    /// A folder's name as the pop-up shows it. LUTs outside any folder are Ungrouped.
    private static func folderTitle(_ folder: String) -> String {
        folder.isEmpty ? "Ungrouped" : (folder as NSString).lastPathComponent
    }

    /// A LUT's name as shown: the last part of its path, without `.cube`.
    private nonisolated static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
