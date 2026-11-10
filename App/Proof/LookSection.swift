import AppKit
import ProofKit
import SwiftUI
import UniformTypeIdentifiers

extension LUTLibrary {
    /// The person's LUTs, in Application Support. The canvas, thumbnails and the Looks section
    /// share it, so a LUT is read and prepared once.
    static let shared = LUTLibrary()
}

/// The LUTs in the library, the folder the Looks section shows, and a small preview of the photo
/// in Edit through each LUT. The previews come from one small render of the edit without its
/// look, so the RAW file is decoded once for all of them, and they're kept until the photo or the
/// rest of its edit changes.
@Observable @MainActor
final class LookBrowser {
    /// Long edge of a preview, in pixels: sharp in a row on a Retina display.
    static let previewSize = 96

    /// Paths of the LUTs, folders first, each folder followed by its contents.
    private(set) var names: [String] = LUTLibrary.shared.names()
    private(set) var previews: [String: NSImage] = [:]
    /// The folder whose LUTs are listed, as a path in the library: "" for those outside any folder.
    var shownFolder = ""

    /// Its own renderer, so previews never wait behind the canvas or evict its decode.
    @ObservationIgnored private let renderer = try? RAWRenderer()
    @ObservationIgnored private var previewed: (url: URL, recipe: EditRecipe)?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// The folders that hold LUTs, in the library's order.
    var folders: [String] { LUTLibrary.folders(in: names) }

    /// The LUTs in the shown folder.
    var shownNames: [String] { LUTLibrary.names(names, in: shownFolder) }

    /// Reads the library's folder again, which the Finder may have changed.
    func reload() {
        let names = LUTLibrary.shared.names()
        guard names != self.names else { return }
        self.names = names
        previews = previews.filter { names.contains($0.key) }
        if !folders.contains(shownFolder) { shownFolder = folders.first ?? "" }
        if let previewed { makePreviews(of: previewed.url, recipe: previewed.recipe, force: true) }
    }

    /// Shows the folder that holds the LUT at `path`.
    func show(folderOf path: String) {
        shownFolder = LUTLibrary.folder(of: path)
    }

    /// The LUT `offset` places from `current` in the shown folder, or the first or last when
    /// `current` isn't in it. `nil` past either end.
    func look(steppingBy offset: Int, from current: String?) -> String? {
        let names = shownNames
        guard !names.isEmpty else { return nil }
        let index = current.flatMap { names.firstIndex(of: $0) }.map { $0 + offset }
            ?? (offset > 0 ? 0 : names.count - 1)
        return names.indices.contains(index) ? names[index] : nil
    }

    /// Copies the `.cube` files and folders at `urls` into the library, shows the folder of the
    /// first LUT added, and returns a message for the files that weren't added.
    func importItems(_ urls: [URL]) async -> String? {
        var failures: [String] = []
        var added: [String] = []
        for url in urls {
            let result = await LUTLibrary.shared.importItem(at: url)
            added += result.names
            failures += result.failures.map { $0.localizedDescription }
        }
        reload()
        if let first = added.first { show(folderOf: first) }
        return failures.isEmpty ? nil : failures.joined(separator: "\n\n")
    }

    /// Opens the library's folder in the Finder, creating it if nothing has been imported yet.
    func revealInFinder() {
        let directory = LUTLibrary.shared.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    /// Makes the previews of `url` with `recipe`, unless they already show it. The previous
    /// previews stay until new ones replace them.
    func makePreviews(of url: URL, recipe: EditRecipe, force: Bool = false) {
        var recipe = recipe
        recipe.look = nil
        guard force || previewed?.url != url || previewed?.recipe != recipe else { return }
        if previewed?.url != url { previews = [:] }
        previewed = (url, recipe)
        previewTask?.cancel()
        let names = names
        previewTask = Task { [renderer] in
            // While a slider is dragged, wait for it to rest.
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            guard let renderer,
                  let base = try? await renderer.thumbnail(of: url, recipe: recipe, maxPixelSize: Self.previewSize),
                  !Task.isCancelled
            else { return }
            for name in names {
                guard let lut = await LUTLibrary.shared.lut(named: name),
                      let image = try? await renderer.applying(lut, to: base),
                      !Task.isCancelled
                else { continue }
                previews[name] = NSImage(cgImage: image, size: .zero)
            }
        }
    }
}

/// The Looks section of the inspector: the strength of the chosen look, a pop-up of the library's
/// folders, and the shown folder's LUTs in a native list, each with a small preview of the photo
/// through it. The list's own selection and keyboard navigation choose looks, so Up and Down Arrow
/// try them in turn. The pop-up also adds `.cube` files and folders, and opens the library in the
/// Finder; files can be dropped on the list too. Reset removes the look, so there is no None row.
struct LookSection: View {
    let library: Library
    @State private var isImporting = false

    private static let cubeType = UTType(filenameExtension: LUTLibrary.fileExtension, conformingTo: .data) ?? .data

    var body: some View {
        Section {
            if looks.names.isEmpty {
                ContentUnavailableView {
                    Label("No Looks", systemImage: "camera.filters")
                } description: {
                    Text("Drag .cube files or folders of them here, or add them.")
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
                                   set: { value in
                                       library.isLookHidden = false
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
                list
            }
        } header: {
            SectionHeader(title: "Looks", canReset: look != nil,
                          isOn: Binding(get: { !library.isLookHidden }, set: { library.isLookHidden = !$0 }),
                          canToggle: look != nil) {
                library.isLookHidden = false
                library.changeEdit { $0.look = nil }
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
        // Coming back from the Finder, where LUTs may have been added, moved or removed.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            looks.reload()
        }
        .task(id: previewKey) {
            guard let previewKey else { return }
            looks.makePreviews(of: previewKey.url, recipe: previewKey.recipe)
        }
    }

    /// The folder pop-up. A folder that holds other folders opens as a submenu.
    private var folderMenu: some View {
        Menu {
            folderItems(under: "")
            Divider()
            Button("Add Looks…") { isImporting = true }
            Button("Reveal in Finder") { looks.revealInFinder() }
        } label: {
            Text(Self.folderTitle(looks.shownFolder))
        }
        .accessibilityLabel("Folder")
        .accessibilityValue(Self.folderTitle(looks.shownFolder))
    }

    /// Menu items for the folders directly below `parent`, and for `parent` itself when it holds
    /// LUTs and has subfolders. LUTs outside any folder come last, as Other.
    private func folderItems(under parent: String) -> AnyView {
        let folders = looks.folders
        let children = Self.childFolders(of: parent, in: folders)
        return AnyView(Group {
            ForEach(children, id: \.self) { child in
                if Self.childFolders(of: child, in: folders).isEmpty {
                    folderToggle(child, title: Self.folderTitle(child))
                } else {
                    Menu(Self.folderTitle(child)) {
                        if folders.contains(child) {
                            folderToggle(child, title: Self.folderTitle(child))
                            Divider()
                        }
                        folderItems(under: child)
                    }
                }
            }
            if parent.isEmpty, folders.contains("") {
                if !children.isEmpty { Divider() }
                folderToggle("", title: Self.folderTitle(""))
            }
        })
    }

    /// A menu item that shows `folder`, checked while it is shown.
    private func folderToggle(_ folder: String, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { looks.shownFolder == folder }, set: { _ in looks.shownFolder = folder }))
    }

    /// The shown folder's LUTs, in a plain list on the section's own background. It scrolls on its
    /// own once it is taller than `maxListHeight`, so the inspector doesn't grow without end.
    private var list: some View {
        List(selection: Binding(get: { look?.lut }, set: { path in
            if let path { choose(path) }
        })) {
            ForEach(looks.shownNames, id: \.self) { path in
                Label {
                    Text(Self.title(of: path))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    preview(of: path)
                }
                .help(path)
                .tag(path)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: min(CGFloat(looks.shownNames.count) * Self.rowHeight + 8, Self.maxListHeight))
        .opacity(library.isLookHidden ? 0.45 : 1)
        .dropDestination(for: URL.self) { urls, _ in
            importItems(urls)
            return true
        }
    }

    private func preview(of path: String) -> some View {
        Group {
            if let image = looks.previews[path] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: Self.previewSide, height: Self.previewSide)
        .clipped()
        .accessibilityHidden(true)
    }

    /// Side of a row's preview, in points: the size of a list row's icon.
    private static let previewSide: CGFloat = 20
    /// A list row's height on macOS, with its spacing, and the tallest the list grows before it scrolls.
    private static let rowHeight: CGFloat = 28
    private static let maxListHeight: CGFloat = 320

    private var looks: LookBrowser { library.looks }
    private var look: Look? { library.selectedEdit?.recipe.look }

    private func choose(_ path: String) {
        guard path != look?.lut else { return }
        library.isLookHidden = false
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

    /// A folder's name as the pop-up shows it. LUTs outside any folder are Other.
    private static func folderTitle(_ folder: String) -> String {
        folder.isEmpty ? "Other" : (folder as NSString).lastPathComponent
    }

    /// A LUT's name as shown: the last part of its path, without `.cube`.
    private static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
