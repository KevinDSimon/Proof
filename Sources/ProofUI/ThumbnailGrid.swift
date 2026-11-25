import ProofKit
import SwiftUI

/// The selected folder's photos, or All Photos, as thumbnails, each shown as soon as `ThumbnailCache` has it, so a
/// folder on a NAS fills in while it is read. Click selects a photo, ⌘-click and ⇧-click select
/// several, the arrow keys move the selection, Esc deselects every photo, and double-click opens
/// the photo in Edit. Return is handled by the Photo menu.
public struct ThumbnailGrid: View {
    @Bindable var library: Library
    /// The photos that pass the filter.
    let photos: [ListedPhoto]
    /// Every listed photo. Thumbnails are loaded for all of them so changing the filter
    /// doesn't read the folder again.
    let allPhotos: [ListedPhoto]

    public init(library: Library, photos: [ListedPhoto], allPhotos: [ListedPhoto]) {
        self.library = library
        self.photos = photos
        self.allPhotos = allPhotos
    }

    /// A photo that was read but couldn't be made into a thumbnail has no entry in `images`.
    @State private var images: [PhotoReference: CGImage] = [:]
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

    #if os(macOS)
    /// The selected photos are outlined, since the keyboard and menus act on them.
    private static let marksSelection = true
    private static let sizes = ThumbnailSize.mac
    private static let spacing: CGFloat = 12
    private static let margin: CGFloat = 20
    #else
    /// A tap opens the photo, so there's no current photo to mark. Selecting several, with its own
    /// marks, is #225.
    private static let marksSelection = false
    private static let sizes = ThumbnailSize.touch
    private static let spacing: CGFloat = 8
    private static let margin: CGFloat = 16
    #endif

    /// The cell size a pinch sets, kept between launches.
    @AppStorage("thumbnailSize") private var storedCellSize = Double(Self.sizes.standard)
    /// The cell size when the current pinch began.
    @State private var pinchStart: CGFloat?
    private var cellSize: CGFloat { Self.sizes.clamped(storedCellSize) }

    public var body: some View {
        ScrollViewReader { scroller in
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: Self.spacing), count: columnCount),
                          spacing: Self.spacing) {
                    let stacks = library.stackMarks
                    ForEach(photos) { photo in
                        cell(for: photo, stack: stacks[photo.id])
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
            #if os(macOS)
            .scrollEdgeEffectStyle(.hard, for: .top)
            #endif
            // Pinching changes the thumbnail size, on a trackpad or a touch screen, also below the
            // last row. Scrolling still works.
            .contentShape(Rectangle())
            .simultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStart ?? cellSize
                        pinchStart = start
                        storedCellSize = Double(Self.sizes.pinched(from: start, by: value.magnification))
                    }
                    .onEnded { _ in pinchStart = nil }
            )
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
                guard let photo = library.browse.selectedPhoto else { return }
                #if os(macOS)
                scroller.scrollTo(photo, anchor: .center)
                #else
                // Centering would scroll a grid shorter than the screen past its top.
                scroller.scrollTo(photo)
                #endif
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($isFocused)
        // Arrow keys move the selection on the Mac; touch has no equivalent.
        #if os(macOS)
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
        #endif
        // With nothing selected, Esc passes on to whatever else handles it.
        .onKeyPress(.escape) {
            guard library.browse.selectedPhoto != nil else { return .ignored }
            library.deselectAll()
            return .handled
        }
        // Coming back from Edit, a photo is selected and the arrow keys should move from it. After a
        // sidebar row is picked nothing is, and the sidebar keeps focus so its selection stays in
        // the highlight; clicking a photo or pressing Tab moves focus here.
        .onAppear { if library.browse.selectedPhoto != nil { isFocused = true } }
        // Loaded again when the LUT library changes, since edited thumbnails show looks.
        .task(id: ThumbnailLoad(photos: allPhotos, lutGeneration: library.looks.generation)) {
            await loadThumbnails()
        }
    }

    private var columnCount: Int {
        let usable = layoutWidth - 2 * Self.margin + Self.spacing
        return max(1, Int(usable / (cellSize + Self.spacing)))
    }

    /// The columns share the layout width, as flexible columns would.
    private var cellWidth: CGFloat {
        let count = CGFloat(columnCount)
        return max(1, (layoutWidth - 2 * Self.margin - (count - 1) * Self.spacing) / count)
    }

    private func cell(for photo: ListedPhoto, stack: StackMark?) -> some View {
        let isSelected = Self.marksSelection && library.browse.selectedPhotos.contains(photo.id)
        return VStack(spacing: 6) {
            // Photos sit on the bottom of their square so the name is right under each one.
            ZStack(alignment: .bottom) {
                if let image = library.editedThumbnails[photo.id] ?? images[photo.id] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(.rect(cornerRadius: SelectionOutline.photoCornerRadius))
                    .ratingBadges(photo.photo.metadata, isEdited: photo.photo.isEdited, isInCloud: photo.photo.isInCloud,
                                  isDownloading: library.downloadingPhotos.contains(photo.id), stack: stack,
                                  isStackOpen: library.isStackOpen(photo.id),
                                  toggleStack: { library.toggleStackAnimated(of: photo.id) }, size: 10)
                        .stackLayers(library.hiddenStackPhotos(of: photo.id).map { library.editedThumbnails[$0] ?? images[$0] },
                                     inStack: stack != nil, step: 5)
                } else if photo.photo.isInCloud {
                    // Not downloaded and iCloud has no thumbnail for it (decision 0050).
                    RoundedRectangle(cornerRadius: SelectionOutline.photoCornerRadius)
                        .fill(.quaternary)
                        .overlay {
                            if library.downloadingPhotos.contains(photo.id) {
                                ProgressView()
                            } else {
                                Image(systemName: "icloud.and.arrow.down")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .help("In iCloud. Open it to download it.")
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
        #if os(macOS)
        .onTapGesture {
            library.click(photo.id, in: photos)
            isFocused = true
        }
        .contextMenu { PhotoContextMenu(library: library, photo: photo.id) }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            library.browse.selectedPhoto = photo.id
            library.browse.edit()
        })
        #else
        // A tap opens the photo, as in Photos. Selecting several and the touch-and-hold menu are #225.
        .onTapGesture {
            library.browse.selectedPhoto = photo.id
            library.browse.edit()
        }
        #endif
        .help(library.selection?.isAcrossFolders == true ? "\(photo.name) in \(library.path(of: photo.folder))" : photo.name)
        .accessibilityElement()
        .accessibilityLabel(RatingBadges.accessibilityLabel(name: photo.name, metadata: photo.photo.metadata,
                                                                 isEdited: photo.photo.isEdited, stack: stack, isInCloud: photo.photo.isInCloud))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Edit") {
            library.browse.selectedPhoto = photo.id
            library.browse.edit()
        }
        .accessibilityAction(named: isSelected ? "Remove from Selection" : "Add to Selection") {
            library.browse.toggle(photo.id, in: photos)
        }
        .accessibilityActions {
            if case .first = stack {
                Button(library.isStackOpen(photo.id) ? "Collapse Stack" : "Open Stack") {
                    library.toggleStackAnimated(of: photo.id)
                }
            }
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
    public static func loadThumbnails(of photos: [ListedPhoto], images: Binding<[PhotoReference: CGImage]>,
                               finished: Binding<Set<PhotoReference>>, library: Library) async {
        let ids = Set(photos.map(\.id))
        let inCloud = Set(photos.filter(\.photo.isInCloud).map(\.id))
        images.wrappedValue = images.wrappedValue.filter { ids.contains($0.key) }
        finished.wrappedValue.formIntersection(ids)
        let unfinished = photos.filter { !finished.wrappedValue.contains($0.id) }
        let urls = unfinished.compactMap { photo in
            library.url(ofPhoto: photo.name, in: photo.folder).map { (photo.id, $0, photo.photo.isEdited) }
        }
        let references = Dictionary(urls.map { ($0.1, $0.0) }, uniquingKeysWith: { first, _ in first })
        let edited = Set(urls.filter(\.2).map(\.1))
        for await (url, image) in ThumbnailCache.shared.thumbnails(for: urls.map(\.1), edited: edited) {
            guard let id = references[url] else { continue }
            // A photo in iCloud shows the system's thumbnail until it is downloaded, when the load
            // runs again and its own thumbnail replaces it.
            if !inCloud.contains(id) { finished.wrappedValue.insert(id) }
            if let image { images.wrappedValue[id] = image }
        }
    }
}

/// What the grid and the filmstrip load thumbnails for: their photos, at a LUT library generation.
public struct ThumbnailLoad: Hashable {
    var photos: [PhotoReference]
    /// Photos in iCloud aren't loaded, so a download loads again.
    var inCloud: Set<PhotoReference>
    var lutGeneration: Int

    public init(photos: [ListedPhoto], lutGeneration: Int) {
        self.photos = photos.map(\.id)
        self.inCloud = Set(photos.filter(\.photo.isInCloud).map(\.id))
        self.lutGeneration = lutGeneration
    }
}
