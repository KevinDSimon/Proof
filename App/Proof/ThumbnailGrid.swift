import ProofKit
import SwiftUI

/// The selected folder's photos, or All Photos, as thumbnails, each shown as soon as `ThumbnailCache` has it, so a
/// folder on a NAS fills in while it is read. Click selects a photo, ⌘-click and ⇧-click select
/// several, the arrow keys move the selection, and double-click opens the photo in Edit. Return
/// is handled by the Photo menu.
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
    /// The LUT library's generation the thumbnails were loaded at.
    @State private var lutGeneration = 0
    /// The grid's width on screen.
    @State private var viewWidth: CGFloat = 0
    /// The width the photos are laid out for. It is the view's width, except while the Info panel
    /// slides in or out: then it is the width the grid will have, so the photos move once to their
    /// new places instead of growing and shrinking with every frame of the slide.
    @State private var layoutWidth: CGFloat = 0
    /// The width the grid is sliding to, while the Info panel moves.
    @State private var slideTarget: CGFloat?
    @FocusState private var isFocused: Bool

    /// Its own renderer, so making thumbnails never waits behind, or evicts, the photo in Edit.
    nonisolated private static let thumbnailRenderer = try? RAWRenderer()
    nonisolated static let cache = ThumbnailCache(renderEdit: { url, edit in
        let lut = await LUTLibrary.shared.lut(for: edit.look)
        return try? await thumbnailRenderer?.thumbnail(of: url, recipe: edit, lut: lut, maxPixelSize: ThumbnailCache.maxPixelSize)
    }, lutVersion: { LUTLibrary.shared.version(of: $0) })
    private static let cellSize: CGFloat = 160
    private static let spacing: CGFloat = 12
    private static let margin: CGFloat = 20

    var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: Self.spacing), count: columnCount),
                          spacing: Self.spacing) {
                    ForEach(photos) { photo in
                        cell(for: photo)
                            .id(photo.id)
                    }
                }
                .padding(Self.margin)
                .frame(width: max(layoutWidth, 1), alignment: .leading)
                // Pinned to the leading edge, so the panel slides over or away from the photos' right side.
                // A minimum of zero, so the photos' layout never holds the grid wider than the window.
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            }
            // A filled title bar with a dividing line, as macOS shows over a view that doesn't
            // scroll, such as an empty folder, so the bar looks the same with or without photos.
            .scrollEdgeEffectStyle(.hard, for: .top)
            // The grid's width comes from the window, never from the photos inside it.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                viewWidth = width
                if let target = slideTarget {
                    // Done when the grid reaches the width it was sliding to.
                    guard abs(width - target) < 1 else { return }
                    slideTarget = nil
                }
                // Resizing the window follows the pointer, without animation.
                if abs(layoutWidth - width) >= 1 { layoutWidth = width }
            }
            .onChange(of: library.isInfoShown) { _, shown in
                guard viewWidth > 0 else { return }
                let target = viewWidth + (shown ? -library.infoPanelWidth : library.infoPanelWidth)
                slideTarget = target
                withAnimation(.smooth(duration: 0.3)) { layoutWidth = target }
            }
            // If the grid never reaches the width expected, as when the panel's width changed
            // while it was closed, it lays out for the width it has.
            .task(id: slideTarget) {
                guard slideTarget != nil else { return }
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled, slideTarget != nil else { return }
                slideTarget = nil
                withAnimation(.smooth(duration: 0.25)) { layoutWidth = viewWidth }
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
        // Loaded again when the LUT library changes, since edited thumbnails show looks.
        .task(id: ThumbnailLoad(photos: allPhotos.map(\.id), lutGeneration: library.looks.generation)) {
            await loadThumbnails()
        }
    }

    private var columnCount: Int {
        let usable = layoutWidth - 2 * Self.margin + Self.spacing
        return max(1, Int(usable / (Self.cellSize + Self.spacing)))
    }

    /// The columns share the layout width, as flexible columns would.
    private var cellWidth: CGFloat {
        let count = CGFloat(columnCount)
        return max(1, (layoutWidth - 2 * Self.margin - (count - 1) * Self.spacing) / count)
    }

    private func cell(for photo: ListedPhoto) -> some View {
        let isSelected = library.browse.selectedPhotos.contains(photo.id)
        return VStack(spacing: 4) {
            // Photos sit on the bottom of their square so the name is right under each one.
            ZStack(alignment: .bottom) {
                if let image = library.editedThumbnails[photo.id] ?? images[photo.id] {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: SelectionOutline.photoCornerRadius))
                        .ratingBadges(photo.photo.metadata, isEdited: photo.photo.isEdited, size: 10)
                } else if finished.contains(photo.id) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                        .help("This photo couldn't be read.")
                } else {
                    RoundedRectangle(cornerRadius: SelectionOutline.photoCornerRadius)
                        .fill(.quaternary)
                }
            }
            .outlined()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .aspectRatio(1, contentMode: .fit)
            Text(photo.name)
                .font(.caption)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                // Full width, so every card in a row is as wide as the cell.
                .frame(maxWidth: .infinity)
                .outlined()
        }
        // The outline wraps the photo and its name, as on a card, but not the empty part of the
        // square above a landscape photo.
        .selectionOutline(isSelected)
        .contentShape(Rectangle())
        .onTapGesture {
            library.click(photo.id, in: photos)
            isFocused = true
        }
        .contextMenu { PhotoContextMenu(library: library, photo: photo.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            library.browse.selectedPhoto = photo.id
            library.browse.edit()
        })
        .help(library.selection?.isAcrossFolders == true ? "\(photo.name) in \(library.path(of: photo.folder))" : photo.name)
        .accessibilityElement()
        .accessibilityLabel(RatingBadges.accessibilityLabel(name: photo.name, metadata: photo.photo.metadata,
                                                                 isEdited: photo.photo.isEdited))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Edit") {
            library.browse.selectedPhoto = photo.id
            library.browse.edit()
        }
        .accessibilityAction(named: isSelected ? "Remove from Selection" : "Add to Selection") {
            library.browse.toggle(photo.id, in: photos)
        }
    }

    private func loadThumbnails() async {
        if lutGeneration != library.looks.generation {
            lutGeneration = library.looks.generation
            finished = []
        }
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

/// What the grid and the filmstrip load thumbnails for: their photos, at a LUT library generation.
struct ThumbnailLoad: Hashable {
    var photos: [PhotoReference]
    var lutGeneration: Int
}
