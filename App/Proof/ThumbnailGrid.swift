import ProofKit
import SwiftUI

/// The selected folder's photos, or All Photos, as thumbnails, each shown as soon as `ThumbnailCache` has it, so a
/// folder on a NAS fills in while it is read. Click selects a photo, the arrow keys move the
/// selection, and double-click opens the photo in Edit. Return is handled by the Photo menu.
struct ThumbnailGrid: View {
    @Bindable var library: Library
    /// The photos that pass the filter.
    let photos: [ListedPhoto]
    /// Every listed photo. Thumbnails are loaded for all of them so changing the filter
    /// doesn't read the folder again.
    let allPhotos: [ListedPhoto]

    /// A photo that was read but couldn't be made into a thumbnail has no entry in `images`.
    @State private var images: [PhotoReference: NSImage] = [:]
    @State private var finished: Set<PhotoReference> = []
    @State private var columnCount = 1
    @FocusState private var isFocused: Bool

    /// Its own renderer, so making thumbnails never waits behind, or evicts, the photo in Edit.
    nonisolated private static let thumbnailRenderer = try? RAWRenderer()
    nonisolated static let cache = ThumbnailCache(renderEdit: { url, edit in
        let lut = await LUTLibrary.shared.lut(for: edit.look)
        return try? await thumbnailRenderer?.thumbnail(of: url, recipe: edit, lut: lut, maxPixelSize: ThumbnailCache.maxPixelSize)
    })
    private static let cellSize: CGFloat = 160
    private static let spacing: CGFloat = 12
    private static let margin: CGFloat = 20

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Self.spacing), count: columnCount),
                          spacing: Self.spacing) {
                    ForEach(photos) { photo in
                        cell(for: photo)
                            .id(photo.id)
                    }
                }
                .padding(Self.margin)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                let usable = width - 2 * Self.margin + Self.spacing
                columnCount = max(1, Int(usable / (Self.cellSize + Self.spacing)))
            }
            .onChange(of: library.browse.selectedPhoto) { _, photo in
                guard let photo else { return }
                withAnimation { scroller.scrollTo(photo) }
            }
            .onAppear {
                if let photo = library.browse.selectedPhoto { scroller.scrollTo(photo, anchor: .center) }
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
        .task(id: allPhotos.map(\.id)) { await loadThumbnails() }
    }

    private func cell(for photo: ListedPhoto) -> some View {
        let isSelected = library.browse.selectedPhoto == photo.id
        return VStack(spacing: 4) {
            // Photos sit on the bottom of their square so the name is right under each one.
            ZStack(alignment: .bottom) {
                if let image = library.editedThumbnails[photo.id] ?? images[photo.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .ratingBadges(photo.photo.metadata, size: 10)
                } else if finished.contains(photo.id) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help("This photo couldn't be read.")
                } else {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                }
            }
            .selectionRing(isSelected)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .aspectRatio(1, contentMode: .fit)
            Text(photo.name)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            library.browse.selectedPhoto = photo.id
            isFocused = true
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            library.browse.selectedPhoto = photo.id
            library.browse.edit()
        })
        .help(library.selection == .allPhotos ? "\(photo.name) in \(library.path(of: photo.folder))" : photo.name)
        .accessibilityElement()
        .accessibilityLabel(RatingBadges.accessibilityLabel(name: photo.name, metadata: photo.photo.metadata))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Edit") {
            library.browse.selectedPhoto = photo.id
            library.browse.edit()
        }
    }

    private func loadThumbnails() async {
        await Self.loadThumbnails(of: allPhotos, images: $images, finished: $finished, library: library)
    }

    /// Loads the thumbnail of each of `photos` from the shared cache into `images` as it arrives,
    /// and marks it in `finished`; a photo that couldn't be read is finished without an image.
    /// Photos already finished keep their thumbnail, so All Photos doesn't start over each time
    /// another folder is read. Used by the grid and the filmstrip.
    static func loadThumbnails(of photos: [ListedPhoto], images: Binding<[PhotoReference: NSImage]>,
                               finished: Binding<Set<PhotoReference>>, library: Library) async {
        let ids = Set(photos.map(\.id))
        images.wrappedValue = images.wrappedValue.filter { ids.contains($0.key) }
        finished.wrappedValue.formIntersection(ids)
        let unfinished = photos.filter { !finished.wrappedValue.contains($0.id) }
        let urls = unfinished.compactMap { photo in
            library.url(ofPhoto: photo.name, in: photo.folder).map { (photo.id, $0, photo.photo.isEdited) }
        }
        let references = Dictionary(urls.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })
        let edited = Set(urls.filter(\.2).map(\.1))
        for await (url, image) in cache.thumbnails(for: urls.map(\.1), edited: edited) {
            guard let id = references[url] else { continue }
            finished.wrappedValue.insert(id)
            if let image { images.wrappedValue[id] = NSImage(cgImage: image, size: .zero) }
        }
    }
}
