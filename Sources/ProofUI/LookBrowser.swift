import CoreGraphics
import Foundation
import Observation
import ProofKit


/// The LUTs in the library, the folder the Looks section shows, and a small preview of the photo
/// in Edit through each LUT. The previews come from one small render of the edit without its
/// look, so the RAW file is decoded once for all of them, and they're kept until the photo or the
/// rest of its edit changes.
@Observable @MainActor
public final class LookBrowser {
    /// Long edge of a preview, in pixels: sharp in a grid tile on a Retina display.
    public static let previewSize = 160

    /// Paths of the LUTs, folders first, each folder followed by its contents.
    public private(set) var names: [String] = LUTLibrary.shared.names()
    public private(set) var previews: [String: CGImage] = [:]
    /// The folder whose LUTs are listed, as a path in the library: "" for those outside any folder.
    public var shownFolder = ""
    /// Counts changes to the library's LUTs, so thumbnails that show looks can be made again.
    public private(set) var generation = 0
    /// Called after the library's LUTs change.
    @ObservationIgnored public var onChange: (() -> Void)?

    /// Its own renderer, so previews never wait behind the canvas or evict its decode.
    @ObservationIgnored private let renderer = try? RAWRenderer()
    @ObservationIgnored private var previewed: (url: URL, recipe: EditRecipe)?
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// Opens a folder in the system's file browser.
    @ObservationIgnored public var openFolder: (URL) -> Void = { _ in }

    /// The folders that hold LUTs, in the library's order.
    public var folders: [String] { LUTLibrary.folders(in: names) }

    /// The LUTs in the shown folder.
    public var shownNames: [String] { LUTLibrary.names(names, in: shownFolder) }

    /// Reads the library's folder again, which the Finder may have changed.
    public func reload() {
        let names = LUTLibrary.shared.names()
        guard names != self.names else { return }
        self.names = names
        generation += 1
        onChange?()
        previews = previews.filter { names.contains($0.key) }
        if !folders.contains(shownFolder) { shownFolder = folders.first ?? "" }
        if let previewed { makePreviews(of: previewed.url, recipe: previewed.recipe, force: true) }
    }

    /// Shows the folder that holds the LUT at `path`.
    public func show(folderOf path: String) {
        shownFolder = LUTLibrary.folder(of: path)
    }

    /// The LUT `offset` places from `current` in the shown folder, or the first or last when
    /// `current` isn't in it. `nil` past either end.
    public func look(steppingBy offset: Int, from current: String?) -> String? {
        let names = shownNames
        guard !names.isEmpty else { return nil }
        let index = current.flatMap { names.firstIndex(of: $0) }.map { $0 + offset }
            ?? (offset > 0 ? 0 : names.count - 1)
        return names.indices.contains(index) ? names[index] : nil
    }

    /// Copies the `.cube` files and folders at `urls` into the library, shows the folder of the
    /// first LUT added, and returns a message for the files that weren't added.
    public func importItems(_ urls: [URL]) async -> String? {
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
    public func revealInFinder() {
        let directory = LUTLibrary.shared.directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        openFolder(directory)
    }

    /// Makes the previews of `url` with `recipe`, unless they already show it. The previous
    /// previews stay until new ones replace them.
    public func makePreviews(of url: URL, recipe: EditRecipe, force: Bool = false) {
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
                previews[name] = image
            }
        }
    }
}
