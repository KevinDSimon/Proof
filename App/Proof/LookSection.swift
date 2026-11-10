import AppKit
import ProofKit
import SwiftUI
import UniformTypeIdentifiers

extension LUTLibrary {
    /// The person's LUTs, in Application Support. The canvas, thumbnails and the Look section share
    /// it, so a LUT is read and prepared once.
    static let shared = LUTLibrary()
}

/// The LUTs in the library and a small preview of the photo in Edit through each. The previews
/// come from one small render of the edit without its look, so the RAW file is decoded once for
/// all of them, and they're kept until the photo or the rest of its edit changes.
@Observable @MainActor
final class LookBrowser {
    /// Long edge of a preview, in pixels: sharp in a tile on a Retina display.
    static let previewSize = 128

    private(set) var names: [String] = []
    /// The photo with no look, for the None tile.
    private(set) var original: NSImage?
    private(set) var previews: [String: NSImage] = [:]

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

    /// Copies `urls` into the library and returns a message for those that weren't added.
    func importFiles(_ urls: [URL]) async -> String? {
        var failures: [String] = []
        for url in urls {
            do {
                _ = try await LUTLibrary.shared.importFile(at: url)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        reload()
        return failures.isEmpty ? nil : failures.joined(separator: "\n\n")
    }

    /// Makes the previews of `url` with `recipe`, unless they already show it. The previous
    /// previews stay until new ones replace them.
    func makePreviews(of url: URL, recipe: EditRecipe, force: Bool = false) {
        var recipe = recipe
        recipe.look = nil
        guard force || previewed?.url != url || previewed?.recipe != recipe else { return }
        if previewed?.url != url {
            original = nil
            previews = [:]
        }
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
            original = NSImage(cgImage: base, size: .zero)
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

/// The Look section of the inspector: the strength of the chosen look, then the library's LUTs as
/// rows with a small preview of the photo through each. The plus button imports more; files can
/// also be dropped on the rows.
struct LookSection: View {
    let library: Library
    @State private var isImporting = false
    @Environment(\.colorScheme) private var colorScheme

    private static let cubeType = UTType(filenameExtension: LUTLibrary.fileExtension, conformingTo: .data) ?? .data

    var body: some View {
        Section {
            if looks.names.isEmpty {
                ContentUnavailableView {
                    Label("No Looks", systemImage: "camera.filters")
                } description: {
                    Text("Drag .cube files here, or import them, to add looks.")
                } actions: {
                    Button("Import…") { isImporting = true }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    importFiles(urls)
                    return true
                }
            } else {
                // First, so choosing a look never moves it.
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
                Group {
                    row(nil)
                    ForEach(looks.names, id: \.self) { row($0) }
                }
                .opacity(library.isLookHidden ? 0.45 : 1)
                .dropDestination(for: URL.self) { urls, _ in
                    importFiles(urls)
                    return true
                }
            }
        } header: {
            SectionHeader(title: "Look", canReset: look != nil,
                          isOn: Binding(get: { !library.isLookHidden }, set: { library.isLookHidden = !$0 }),
                          canToggle: look != nil,
                          add: ("Import Looks", { isImporting = true })) {
                library.isLookHidden = false
                library.changeEdit { $0.look = nil }
            }
        }
        .disabled(library.selectedEdit == nil)
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [Self.cubeType],
                      allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): importFiles(urls)
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .onAppear { looks.reload() }
        .task(id: previewKey) {
            guard let previewKey else { return }
            looks.makePreviews(of: previewKey.url, recipe: previewKey.recipe)
        }
    }

    /// One look as a row: a small preview, then its name. The chosen row is inverted, as
    /// Proof marks selection without color.
    private func row(_ name: String?) -> some View {
        let isSelected = look?.lut == name
        let title = name.map(Self.title(of:)) ?? "None"
        return Button {
            library.isLookHidden = false
            library.changeEdit { recipe in
                recipe.look = name.map { Look(lut: $0, strength: recipe.look?.strength ?? 1) }
            }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let image = name.map({ looks.previews[$0] }) ?? looks.original {
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
            .padding(4)
            .foregroundStyle(isSelected ? Color(white: colorScheme == .dark ? 0 : 1) : Color.primary)
            .background {
                if isSelected {
                    // Plain black or white: the panel's vibrancy blends system label colors toward gray.
                    RoundedRectangle(cornerRadius: 6).fill(Color(white: colorScheme == .dark ? 1 : 0))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The highlight reaches the row's edges, inside the Form's own inset.
        .padding(.horizontal, -4)
        .help(name ?? "No look")
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// Side of a row's preview, in points.
    private static let previewSide: CGFloat = 28

    private var looks: LookBrowser { library.looks }
    private var look: Look? { library.selectedEdit?.recipe.look }

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

    private func importFiles(_ urls: [URL]) {
        Task {
            if let message = await looks.importFiles(urls) { library.errorMessage = message }
        }
    }

    /// A LUT's name as shown: its file name without `.cube`.
    private static func title(of name: String) -> String {
        (name as NSString).deletingPathExtension
    }
}
