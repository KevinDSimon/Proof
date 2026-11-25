import AppKit
import ProofKit
import ProofUI
import SwiftUI
import UniformTypeIdentifiers

/// The Looks section of the inspector: the strength of the chosen look, a pop-up of the library's
/// folders, and the shown folder's LUTs as a grid of small previews of the photo through each.
/// The arrow keys move through the grid, choosing as they go. The pop-up also adds `.cube` files
/// and folders, and opens the library in the Finder; files can be dropped on the grid too. Reset removes the look, so there is no None row.
struct LookSection: View {
    let library: Library
    @State private var isImporting = false
    @FocusState private var isGridFocused: Bool

    private static let cubeType = UTType(filenameExtension: LUTLibrary.fileExtension, conformingTo: .data) ?? .data

    var body: some View {
        InspectorCard(title: "Looks", isOn: library.isOnBinding(.look), canReset: look != nil,
                      reset: { library.changeEdit { $0.look = nil } }) {
            if looks.names.isEmpty {
                // One line of description, so the empty card isn't much taller than the others.
                ContentUnavailableView {
                    Label("No Looks", systemImage: "camera.filters")
                } description: {
                    Text("Drag .cube files or folders here.")
                } actions: {
                    Button("Add Looks…") { isImporting = true }
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
                                   set: { value in library.changeEdit { $0.look?.strength = value / 100 } }),
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
        .disabled(library.selectedEdit == nil)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [Self.cubeType, .folder],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importItems(urls)
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
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

    /// The folder pop-up, titled with the chosen look, or with the shown folder when no look in
    /// it is chosen. A folder that holds other folders opens as a submenu.
    private var folderMenu: some View {
        MenuPopUp(title: menuTitle, items: folderItems(under: "") + [
            .separator,
            .action("Add Looks…") { isImporting = true },
            .action("Reveal in Finder") { looks.revealInFinder() },
        ])
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Looks folder")
    }

    private var menuTitle: String {
        if let look, looks.shownNames.contains(look.lut) { return Self.title(of: look.lut) }
        return Self.folderTitle(looks.shownFolder)
    }

    /// Menu items for the folders directly below `parent`, and for `parent` itself when it holds
    /// LUTs and has subfolders. LUTs outside any folder come last, as Ungrouped.
    private func folderItems(under parent: String) -> [MenuPopUp.Item] {
        let folders = looks.folders
        let children = Self.childFolders(of: parent, in: folders)
        var items: [MenuPopUp.Item] = children.map { child in
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
    private func folderItem(_ folder: String) -> MenuPopUp.Item {
        .action(Self.folderTitle(folder), isChecked: looks.shownFolder == folder) { looks.shownFolder = folder }
    }

    /// The shown folder's LUTs as a grid of previews of the whole photo. The chosen one has the
    /// filmstrip's outline, and its name is the pop-up's title; each tile's name is in its help tag.
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
        return preview(of: path)
            .selectionOutline(isSelected, padding: 4)
            .contentShape(Rectangle())
            .onTapGesture {
                isGridFocused = true
                choose(path)
            }
            .help(Self.title(of: path))
            .accessibilityElement()
            .accessibilityLabel(Self.title(of: path))
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { choose(path) }
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

    /// The folders, among `folders` and the folders around them, directly below `parent`.
    private static func childFolders(of parent: String, in folders: [String]) -> [String] {
        var children: [String] = []
        for folder in folders where !folder.isEmpty {
            let components = folder.split(separator: "/").map(String.init)
            let depth = parent.isEmpty ? 0 : parent.split(separator: "/").count
            guard components.count > depth,
                  parent.isEmpty || folder.hasPrefix(parent + "/") else { continue }
            let child = components[...depth].joined(separator: "/")
            if !children.contains(child) { children.append(child) }
        }
        return children
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
    private static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
