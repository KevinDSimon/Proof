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

/// The Looks section of the inspector: the strength of the chosen look, then the library's LUTs as
/// slim rows with a small preview of the photo through each, in folders that open and close.
/// Up and Down arrows try the looks in turn. Add imports `.cube` files and folders; they can also be
/// dropped on the list. Reset removes the look, so there is no None row.
struct LookSection: View {
    let library: Library
    @State private var isImporting = false
    @FocusState private var isListFocused: Bool
    @Environment(\.colorScheme) private var colorScheme

    private static let cubeType = UTType(filenameExtension: LUTLibrary.fileExtension, conformingTo: .data) ?? .data

    /// A line in the list: a folder, or a LUT inside the open folders.
    private enum Row: Hashable {
        case folder(path: String, depth: Int)
        case look(path: String, depth: Int)
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

    /// The rows in one focusable list, so the arrow keys step through the looks.
    private var list: some View {
        VStack(spacing: 0) {
            ForEach(rows, id: \.self) { row in
                switch row {
                case .folder(let path, let depth): folderRow(path, depth: depth)
                case .look(let path, let depth): lookRow(path, depth: depth)
                }
            }
        }
        .opacity(library.isLookHidden ? 0.45 : 1)
        .focusable()
        .focused($isListFocused)
        .onKeyPress(.downArrow) { step(by: 1) }
        .onKeyPress(.upArrow) { step(by: -1) }
        .dropDestination(for: URL.self) { urls, _ in
            importItems(urls)
            return true
        }
    }

    /// Folders and the LUTs in open folders, in the library's order.
    private var rows: [Row] {
        var rows: [Row] = []
        var shownFolders: Set<String> = []
        for name in looks.names {
            let folders = LookBrowser.folders(containing: name)
            var isOpen = true
            for (depth, folder) in folders.enumerated() where isOpen {
                if shownFolders.insert(folder).inserted { rows.append(.folder(path: folder, depth: depth)) }
                isOpen = looks.expandedFolders.contains(folder)
            }
            if isOpen { rows.append(.look(path: name, depth: folders.count)) }
        }
        return rows
    }

    private func folderRow(_ path: String, depth: Int) -> some View {
        let isExpanded = looks.expandedFolders.contains(path)
        return HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: Self.previewSide)
            Text(Self.title(of: path))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Self.rowPadding)
        .padding(.leading, CGFloat(depth) * Self.indent)
        .contentShape(Rectangle())
        .onTapGesture {
            isListFocused = true
            withAnimation(.snappy(duration: 0.2)) {
                if isExpanded { looks.expandedFolders.remove(path) } else { looks.expandedFolders.insert(path) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isExpanded ? "Open" : "Closed")
        .accessibilityAction { looks.expandedFolders.formSymmetricDifference([path]) }
    }

    /// One look: a small preview, then its name. The chosen row is inverted, as Proof marks
    /// selection without color.
    private func lookRow(_ path: String, depth: Int) -> some View {
        let isSelected = look?.lut == path
        let title = Self.title(of: path)
        return HStack(spacing: 6) {
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
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.vertical, Self.rowPadding)
        .padding(.leading, CGFloat(depth) * Self.indent)
        .padding(.horizontal, 4)
        .foregroundStyle(isSelected ? Color(white: colorScheme == .dark ? 0 : 1) : Color.primary)
        .background {
            if isSelected {
                // Plain black or white: the panel's vibrancy blends system label colors toward gray.
                RoundedRectangle(cornerRadius: 5).fill(Color(white: colorScheme == .dark ? 1 : 0))
            }
        }
        // The highlight reaches the row's edges, inside the Form's own inset.
        .padding(.horizontal, -4)
        .contentShape(Rectangle())
        .onTapGesture {
            isListFocused = true
            choose(path)
        }
        .help(path)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { choose(path) }
    }

    /// Side of a row's preview, in points.
    private static let previewSide: CGFloat = 18
    private static let rowPadding: CGFloat = 3
    /// How far each folder level is indented: the width of a preview and its gap.
    private static let indent: CGFloat = 24

    private var looks: LookBrowser { library.looks }
    private var look: Look? { library.selectedEdit?.recipe.look }

    private func choose(_ path: String) {
        library.isLookHidden = false
        library.changeEdit { recipe in
            recipe.look = Look(lut: path, strength: recipe.look?.strength ?? 1)
        }
    }

    /// Chooses the look `offset` rows from the chosen one among those shown, or the first.
    private func step(by offset: Int) -> KeyPress.Result {
        let shown = rows.compactMap { row -> String? in
            if case .look(let path, _) = row { path } else { nil }
        }
        guard !shown.isEmpty else { return .ignored }
        let index = look.flatMap { shown.firstIndex(of: $0.lut) }.map { $0 + offset } ?? 0
        choose(shown[min(max(index, 0), shown.count - 1)])
        return .handled
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
