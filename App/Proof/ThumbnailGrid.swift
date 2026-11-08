import ProofKit
import SwiftUI

/// The selected folder's photos as thumbnails, each shown as soon as `ThumbnailCache` has it, so a
/// folder on a NAS fills in while it is read. Click selects a photo, the arrow keys move the
/// selection, and double-click opens the photo in Edit. Return is handled by the Photo menu.
struct ThumbnailGrid: View {
    @Bindable var library: Library
    let folder: FileReference
    /// The photos that pass the filter.
    let photos: [FolderContents.Photo]
    /// Every photo in the folder. Thumbnails are loaded for all of them so changing the filter
    /// doesn't read the folder again.
    let allPhotos: [FolderContents.Photo]

    /// A photo that was read but couldn't be made into a thumbnail has no entry in `images`.
    @State private var images: [String: NSImage] = [:]
    @State private var finished: Set<String> = []
    @State private var columnCount = 1
    @FocusState private var isFocused: Bool

    private struct LoadKey: Equatable {
        var folder: FileReference
        var names: [String]
    }

    static let cache = ThumbnailCache()
    private static let cellSize: CGFloat = 160
    private static let spacing: CGFloat = 12
    private static let margin: CGFloat = 20

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columnCount),
                          spacing: Self.spacing) {
                    ForEach(photos, id: \.name) { photo in
                        cell(for: photo)
                            .id(photo.name)
                    }
                }
                .padding(Self.margin)
            }
            // A soft fade under the toolbar instead of a separator line.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let usable = width - 2 * Self.margin + Self.spacing
                columnCount = max(1, Int(usable / (Self.cellSize + Self.spacing)))
            }
            .onChange(of: library.browse.selectedPhoto) { _, name in
                guard let name else { return }
                withAnimation { scroller.scrollTo(name) }
            }
            .onAppear {
                if let name = library.browse.selectedPhoto { scroller.scrollTo(name, anchor: .center) }
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        .onMoveCommand { direction in
            let move: BrowseState.Move? = switch direction {
            case .left: .left
            case .right: .right
            case .up: .up
            case .down: .down
            @unknown default: nil
            }
            if let move { library.browse.move(move, in: photos, columns: columnCount) }
        }
        .onAppear { isFocused = true }
        .task(id: LoadKey(folder: folder, names: allPhotos.map(\.name))) { await loadThumbnails() }
    }

    private func cell(for photo: FolderContents.Photo) -> some View {
        let isSelected = library.browse.selectedPhoto == photo.name
        return ZStack {
            if let image = images[photo.name] {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else if finished.contains(photo.name) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .help("This photo couldn't be read.")
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
            }
        }
        .selectionRing(isSelected)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture {
            library.browse.selectedPhoto = photo.name
            isFocused = true
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            library.browse.selectedPhoto = photo.name
            library.browse.edit()
        })
        .help(photo.name)
        .accessibilityElement()
        .accessibilityLabel(photo.name)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Edit") {
            library.browse.selectedPhoto = photo.name
            library.browse.edit()
        }
    }

    private func loadThumbnails() async {
        images = [:]
        finished = []
        await Self.loadThumbnails(of: allPhotos, in: folder, library: library) { name, image in
            finished.insert(name)
            if let image { images[name] = image }
        }
    }

    /// Delivers the thumbnail of each of `photos` by name as it arrives from the shared cache; the
    /// image is `nil` if the photo couldn't be read. Used by the grid and the filmstrip.
    static func loadThumbnails(of photos: [FolderContents.Photo], in folder: FileReference, library: Library,
                               deliver: (String, NSImage?) -> Void) async {
        let urls = photos.compactMap { photo in
            library.url(ofPhoto: photo.name, in: folder).map { (photo.name, $0) }
        }
        let names = Dictionary(urls.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })
        for await (url, image) in cache.thumbnails(for: urls.map(\.1)) {
            guard let name = names[url] else { continue }
            deliver(name, image.map { NSImage(cgImage: $0, size: .zero) })
        }
    }
}
