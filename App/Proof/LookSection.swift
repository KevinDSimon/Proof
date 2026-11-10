import AppKit
import ProofKit
import SwiftUI
import UniformTypeIdentifiers

extension LUTLibrary {
    /// The person's LUTs, in Application Support. The canvas, thumbnails and the Looks section share
    /// it, so a LUT is read and prepared once.
    static let shared = LUTLibrary()
}

/// The LUTs in the library and a small preview of the photo in Edit through each. The previews
/// come from one small render of the edit without its look, so the RAW file is decoded once for
/// all of them, and they're kept until the photo or the rest of its edit changes.
@Observable @MainActor
final class LookBrowser {
    /// Long edge of a preview, in pixels: sharp in a row on a Retina display.
    static let previewSize = 96

    /// Paths of the LUTs, folders first, each folder followed by its contents.
    private(set) var names: [String] = []
    private(set) var previews: [String: NSImage] = [:]
    /// Folders shown open, by path. They stay open across photos.
    var expandedFolders: Set<String> = []

    /// Its own renderer, so previews never wait behind the canvas or evict its decode.
    @ObservationIgnored private let renderer = try? RAWRenderer()
    @ObservationIgnored private var previewed: (url: URL, recipe: EditRecipe)?
    @ObservationIgnored private var previewTask: Task<Void, Never>?

    /// Reads the library's folder again, which the Finder may have changed.
    func reload() {
        let names = LUTLibrary.shared.names()
        guard names != self.names else { return }
        self.names = names
        previews = previews.filter { names.contains($0.key) }
        if let previewed { makePreviews(of: previewed.url, recipe: previewed.recipe, force: true) }
    }

    /// Copies the `.cube` files and folders at `urls` into the library, opens the folders added,
    /// and returns a message for the files that weren't added.
    func importItems(_ urls: [URL]) async -> String? {
        var failures: [String] = []
        for url in urls {
            let result = await LUTLibrary.shared.importItem(at: url)
            for name in result.names { expandedFolders.formUnion(Self.folders(containing: name)) }
            failures += result.failures.map { $0.localizedDescription }
        }
        reload()
        return failures.isEmpty ? nil : failures.joined(separator: "\n\n")
    }

    /// The paths of the folders around the LUT at `path`, outermost first.
    static func folders(containing path: String) -> [String] {
        let components = path.split(separator: "/").map(String.init).dropLast()
        return components.indices.map { components[...$0].joined(separator: "/") }
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

/// The Looks section of the inspector: the strength of the chosen look, then the library in a
/// plain outline list, folders first, each look with a small preview of the photo through it. The
/// list's own selection and keyboard navigation choose looks, so Up and Down Arrow try them in turn,
/// and Right and Left Arrow move into and out of folders.
/// Add imports `.cube` files and folders; they can also be dropped on the list. Reset removes the
/// look, so there is no None row.
struct LookSection: View {
    let library: Library
    @State private var isImporting = false
    /// The list's selection: the chosen look, or a folder while moving through the list by keyboard.
    @State private var selection: String?

    private static let cubeType = UTType(filenameExtension: LUTLibrary.fileExtension, conformingTo: .data) ?? .data

    /// A folder, with its contents, or a LUT.
    private struct Node: Identifiable {
        let id: String
        var children: [Node]?
    }

    var body: some View {
        Section {
            if looks.names.isEmpty {
                ContentUnavailableView {
                    Label("No Looks", systemImage: "camera.filters")
                } description: {
                    Text("Drag .cube files or folders of them here, or click Add.")
                } actions: {
                    Button("Add Looks…") { isImporting = true }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    importItems(urls)
                    return true
                }
            } else {
                // First, so choosing a look or opening a folder never moves it.
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
                list
            }
        } header: {
            SectionHeader(title: "Looks", canReset: look != nil,
                          isOn: Binding(get: { !library.isLookHidden }, set: { library.isLookHidden = !$0 }),
                          canToggle: look != nil,
                          add: ("Add", "Add .cube files, or folders of them", { isImporting = true })) {
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
            revealChosenLook()
        }
        .onChange(of: look?.lut) { revealChosenLook() }
        .task(id: previewKey) {
            guard let previewKey else { return }
            looks.makePreviews(of: previewKey.url, recipe: previewKey.recipe)
        }
    }

    /// The library as a plain outline list on the section's own background. It scrolls on its
    /// own once it is taller than `maxListHeight`, so the inspector doesn't grow without end.
    /// Folders can be selected so the keyboard can reach them: Right Arrow opens a folder or moves
    /// into an open one, and Left Arrow closes it or moves from a look out to its folder.
    private var list: some View {
        List(selection: $selection) {
            ForEach(tree) { node($0) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .frame(height: listHeight)
        .onChange(of: selection) {
            if let selection, looks.names.contains(selection) { choose(selection) }
        }
        .onChange(of: look?.lut, initial: true) { selection = look?.lut }
        .onKeyPress(.rightArrow) { moveIn() }
        .onKeyPress(.leftArrow) { moveOut() }
        .opacity(library.isLookHidden ? 0.45 : 1)
        .dropDestination(for: URL.self) { urls, _ in
            importItems(urls)
            return true
        }
    }

    private func node(_ node: Node) -> AnyView {
        if let children = node.children {
            AnyView(
                DisclosureGroup(isExpanded: Binding(
                    get: { looks.expandedFolders.contains(node.id) },
                    set: { if $0 { looks.expandedFolders.insert(node.id) } else { looks.expandedFolders.remove(node.id) } }
                )) {
                    ForEach(children) { self.node($0) }
                } label: {
                    Label(Self.title(of: node.id), systemImage: "folder")
                        .tag(node.id)
                }
            )
        } else {
            AnyView(
                Label {
                    Text(Self.title(of: node.id))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } icon: {
                    preview(of: node.id)
                }
                .help(node.id)
                .tag(node.id)
            )
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

    /// Tall enough for the rows shown, up to `maxListHeight`.
    private var listHeight: CGFloat {
        min(CGFloat(visibleRowCount(tree)) * Self.rowHeight + 8, Self.maxListHeight)
    }

    private func visibleRowCount(_ nodes: [Node]) -> Int {
        nodes.reduce(0) { count, node in
            guard let children = node.children, looks.expandedFolders.contains(node.id) else { return count + 1 }
            return count + 1 + visibleRowCount(children)
        }
    }

    /// The library's paths as folders and LUTs, in the library's order: folders first.
    private var tree: [Node] {
        Self.nodes(looks.names.map { $0.split(separator: "/").map(String.init) }, under: [])
    }

    private static func nodes(_ paths: [[String]], under folder: [String]) -> [Node] {
        var nodes: [Node] = []
        var index = 0
        while index < paths.count {
            let path = paths[index]
            if path.count == 1 {
                nodes.append(Node(id: (folder + path).joined(separator: "/")))
                index += 1
            } else {
                // The library lists each folder's contents together, so they are consecutive.
                let name = path[0]
                var end = index
                while end < paths.count, paths[end].count > 1, paths[end][0] == name { end += 1 }
                let inside = paths[index..<end].map { Array($0.dropFirst()) }
                nodes.append(Node(id: (folder + [name]).joined(separator: "/"), children: Self.nodes(inside, under: folder + [name])))
                index = end
            }
        }
        return nodes
    }

    private var looks: LookBrowser { library.looks }
    private var look: Look? { library.selectedEdit?.recipe.look }

    private func choose(_ path: String) {
        guard path != look?.lut else { return }
        library.isLookHidden = false
        library.changeEdit { recipe in
            recipe.look = Look(lut: path, strength: recipe.look?.strength ?? 1)
        }
    }

    /// Right Arrow on a folder: opens it, or if it is open, selects the first thing in it.
    private func moveIn() -> KeyPress.Result {
        guard let selection, let children = Self.children(of: selection, in: tree) else { return .ignored }
        if !looks.expandedFolders.contains(selection) {
            looks.expandedFolders.insert(selection)
        } else if let first = children.first {
            self.selection = first.id
        }
        return .handled
    }

    /// Left Arrow: closes an open folder, or selects the folder around a look or a closed folder.
    private func moveOut() -> KeyPress.Result {
        guard let selection else { return .ignored }
        if Self.children(of: selection, in: tree) != nil, looks.expandedFolders.contains(selection) {
            looks.expandedFolders.remove(selection)
            return .handled
        }
        guard let folder = LookBrowser.folders(containing: selection).last else { return .ignored }
        self.selection = folder
        return .handled
    }

    /// The contents of the folder at `path`, or `nil` if `path` isn't a folder.
    private static func children(of path: String, in nodes: [Node]) -> [Node]? {
        for node in nodes {
            if node.id == path { return node.children }
            if let children = node.children, path.hasPrefix(node.id + "/"),
               let found = Self.children(of: path, in: children) { return found }
        }
        return nil
    }

    /// Opens the folders around the chosen look, so it can be seen.
    private func revealChosenLook() {
        guard let path = look?.lut else { return }
        looks.expandedFolders.formUnion(LookBrowser.folders(containing: path))
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

    /// A LUT's or folder's name as shown: the last part of its path, without `.cube`.
    private static func title(of path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}
