import ProofKit
import ProofUI
import SwiftUI

@main
struct ProofApp: App {
    @State private var library = Library(platform: .iOS)

    var body: some Scene {
        // One window, as on the Mac. The interface is dark in both system appearances through
        // UIUserInterfaceStyle in the Info.plist, so launch, sheets and alerts follow too.
        WindowGroup {
            ContentView(library: library)
        }
    }
}

/// The library beside the grid on iPad; on iPhone and in a narrow iPad window, one stack of
/// library, grid and photo, as in Notes, with the standard back button and edge swipe
/// (decision 0048).
struct ContentView: View {
    @Bindable var library: Library
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// In compact width, whether a row's grid is pushed onto the library.
    @State private var compactPath: [BrowseScreen] = []
    @State private var renderer = try? RAWRenderer()
    @State private var columnVisibility = NavigationSplitViewVisibility.automatic
    /// The sidebar's visibility in Browse, restored when Edit ends.
    @State private var browseColumnVisibility = NavigationSplitViewVisibility.automatic

    var body: some View {
        Group {
            if sizeClass == .compact { compactStack } else { splitView }
        }
        // Inside the folder picker's view: two presentations on one view can keep one from opening.
        .revertConfirmation(library)
        .fileImporter(isPresented: $library.isChoosingFolder, allowedContentTypes: [.folder],
                      allowsMultipleSelection: library.folderPickerAllowsSeveral) { result in
            switch result {
            case .success(let urls): library.chose(urls)
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .fileDialogMessage(Text(library.folderPickerMessage))
        .fileDialogConfirmationLabel(Text(library.folderPickerConfirmation))
        .alert("Something Went Wrong", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        // Select ends on another row, and on opening a photo from the menu.
        .onChange(of: library.selection) { library.isSelectingPhotos = false }
        .onChange(of: library.isEditing) {
            if library.isEditing { library.isSelectingPhotos = false }
            // Edit hides the library so the photo has the width, as on the Mac; the sidebar
            // button brings it back.
            if library.isEditing {
                browseColumnVisibility = columnVisibility
                columnVisibility = .detailOnly
            } else {
                columnVisibility = browseColumnVisibility
            }
        }
    }

    private var splitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FolderSidebar(library: library)
                .navigationTitle("Library")
        } detail: {
            NavigationStack {
                grid
                    // A grid of its own for each row, so a row picked while another's grid is
                    // showing loads its thumbnails.
                    .id(library.selection)
            }
        }
    }

    /// A split view collapsed to a stack would keep the grid in a stack of its own inside it,
    /// where its large title doesn't follow its scrolling and its thumbnails don't load; one
    /// stack has neither problem. Picking a row pushes its grid, and going back clears the row,
    /// so picking it again opens it again.
    private var compactStack: some View {
        NavigationStack(path: $compactPath) {
            Group {
                // With no folders there is nothing to list, so the empty state shows instead.
                if library.locations.isEmpty {
                    PhotoBrowser(library: library)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.interfaceBackground.ignoresSafeArea())
                } else {
                    FolderSidebar(library: library)
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: BrowseScreen.self) { _ in grid }
        }
        .onChange(of: library.selection, initial: true) { _, selection in
            if selection != nil, compactPath.isEmpty { compactPath = [.grid] }
        }
        .onChange(of: compactPath) { _, path in
            if path.isEmpty { library.selection = nil }
        }
    }

    /// The selected row's photos, with Browse's toolbar, pushing the photo in Edit.
    private var grid: some View {
        PhotoBrowser(library: library)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.interfaceBackground.ignoresSafeArea())
            .navigationTitle(browseTitle)
            // A large title, as in Notes and Photos, that shrinks into the bar on scrolling.
            .navigationBarTitleDisplayMode(.large)
            .toolbar { browseToolbar }
            // Select All takes the back button's place while selecting, as in Files.
            .navigationBarBackButtonHidden(library.isSelectingPhotos)
            .navigationDestination(isPresented: isEditing) {
                PhotoView(library: library, renderer: renderer)
            }
    }

    /// Browse has one More menu, with Select and the filter, so the bar stays clear on iPhone.
    /// While selecting, the bar has Select All, the filter and Done, and a bottom toolbar rates and
    /// flags the selected photos, as in Notes.
    @ToolbarContentBuilder private var browseToolbar: some ToolbarContent {
        if library.isSelectingPhotos {
            let allSelected = library.browse.selectedPhotos.count == library.shownPhotos.count
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected { library.deselectAll() } else { library.browse.selectAll(library.shownPhotos) }
                }
            }
            // The filter stays at hand while selecting; photos it hides are deselected, so Rating
            // and Flag never reach photos out of sight.
            ToolbarItem {
                Menu {
                    FilterMenu(library: library)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease").filterBadge(library.filter)
                }
                .accessibilityLabel("Filter")
                .accessibilityValue(library.filter.filtersOnDescription)
            }
            ToolbarSpacer(.fixed)
            // The one filled use of the highlight color: the button that ends selecting, as in Notes.
            ToolbarItem {
                Button("Done", systemImage: "checkmark", role: .confirm) { library.isSelectingPhotos = false }
                    .tint(.highlight)
            }
            let photos = library.selectedPhotosInOrder
            ToolbarItemGroup(placement: .bottomBar) {
                Menu("Rating", systemImage: "star") {
                    RatingPicker(library: library, photos: photos).pickerStyle(.inline)
                }
                .disabled(photos.isEmpty)
                Spacer()
                Menu("Flag", systemImage: "flag") {
                    FlagPicker(library: library, photos: photos).pickerStyle(.inline)
                }
                .disabled(photos.isEmpty)
            }
        } else if library.selection != nil, !library.isEditing {
            ToolbarItem {
                Menu {
                    Button("Select", systemImage: "checkmark.circle") { library.isSelectingPhotos = true }
                        .disabled(library.visiblePhotos.isEmpty)
                    Menu {
                        FilterMenu(library: library)
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease")
                        if !library.filter.isEmpty { Text(library.filter.summary) }
                    }
                } label: {
                    Image(systemName: "ellipsis").filterBadge(library.filter)
                }
                .accessibilityLabel("More")
                .accessibilityValue(library.filter.filtersOnDescription)
            }
        }
    }

    /// Going back from the photo, by the back button or the edge swipe, returns to Browse.
    private var isEditing: Binding<Bool> {
        Binding(get: { library.isEditing },
                set: { if !$0, library.isEditing { library.browse.finishEditing() } })
    }

    // The grid's title stays the row's while the photo is pushed, so the back button names it.
    private var browseTitle: String {
        guard library.isSelectingPhotos else { return library.rowTitle }
        let count = library.browse.selectedPhotos.count
        // As in Notes.
        return count == 0 ? "Select Photos" : "\(count) Selected"
    }
}

private extension View {
    /// A single photo reverts without asking, as Undo in Edit brings it back. Several may never be
    /// opened again, so they ask first, as on the Mac.
    func revertConfirmation(_ library: Library) -> some View {
        @Bindable var library = library
        return confirmationDialog("Revert \(library.photosPendingRevert.count) photos to their originals?",
                                  isPresented: $library.isConfirmingRevert, titleVisibility: .visible) {
            Button("Revert \(library.photosPendingRevert.count) Photos", role: .destructive) { library.revertPendingPhotos() }
        } message: {
            Text("Their edits are removed. To bring one back, open it in Edit and choose Undo before quitting Proof.")
        }
    }

    /// A yellow badge counting the filter parts that are set, on the button that holds the
    /// filter. The system's toolbar badge is always red (decision 0041).
    func filterBadge(_ filter: FilterCriteria) -> some View {
        overlay(alignment: .topTrailing) {
            if !filter.isEmpty {
                Text("\(filter.setParts)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.black)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.highlight, in: .circle)
                    .offset(x: 12, y: -12)
            }
        }
    }
}

private extension FilterCriteria {
    /// How many parts are set; a filter that matches nothing counts as one.
    var setParts: Int { max(activeCount, 1) }

    var filtersOnDescription: String {
        isEmpty ? "" : "\(setParts) \(setParts == 1 ? "filter" : "filters") on"
    }
}

/// What compact width pushes onto the library.
private enum BrowseScreen: Hashable {
    case grid
}

/// The photo in Edit, centered on the canvas with a margin, with the filmstrip under it. The
/// adjustments are in the trailing inspector in regular width, and in a sheet below the photo in
/// compact width, as `.inspector` presents there. Undo and Redo lead the toolbar, as in Photos.
private struct PhotoView: View {
    @Bindable var library: Library
    let renderer: RAWRenderer?
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var sheetHeight = PresentationDetent.inspectorSmall
    /// The top of the inspector's sheet, in global coordinates, while it is up.
    @State private var sheetTop: CGFloat?
    /// The bottom of the space the photo and filmstrip are laid out in, in global coordinates.
    @State private var photoAreaBottom: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            photo
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(library.canvasColor.color)
            if library.isFilmstripShown {
                Filmstrip(library: library, photos: library.shownPhotos)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // The photo and filmstrip fit above the sheet, so it never covers them.
        .padding(.bottom, sheetInset)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { photoAreaBottom = $0 }
        .animation(.snappy(duration: 0.25), value: library.isFilmstripShown)
        .background(Color.interfaceBackground.ignoresSafeArea())
        .navigationTitle(library.windowTitle)
        .navigationBarTitleDisplayMode(.inline)
        .inspector(isPresented: $library.isInspectorShown) {
            Group {
                if isEditable {
                    // Looks and the tools drawn on the photo come to iOS in #232 and #231.
                    AdjustmentsInspector(library: library, renderer: renderer, tools: [])
                }
            }
            // Wider than the Mac's: iOS switches are larger, and the longest header, "Lens
            // Corrections" beside Reset and its switch, needs the room.
            .inspectorColumnWidth(min: 360, ideal: 380, max: 460)
            // In compact width the inspector is a sheet. These apply to it only there.
            .environment(\.isInspectorSheet, sizeClass == .compact)
            .presentationBackground(Color.sheetBackground)
            .presentationDetents(sheetHeights, selection: $sheetHeight)
            .presentationBackgroundInteraction(.enabled)
            .presentationContentInteraction(.scrolls)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { top in
                if sizeClass == .compact { sheetTop = top }
            }
            .onDisappear { sheetTop = nil }
            // Presented from the sheet, which is the top presentation while it is up.
            .sheet(isPresented: compactHistory(whileSheetIsUp: true)) { historySheet }
        }
        // While the inspector's sheet is down, History presents from here.
        .sheet(isPresented: compactHistory(whileSheetIsUp: false)) { historySheet }
        .onChange(of: sizeClass) { if sizeClass != .compact { sheetTop = nil } }
        // A phone in landscape has room for the photo only above a small sheet.
        .onChange(of: verticalSizeClass, initial: true) {
            if verticalSizeClass == .compact { sheetHeight = .inspectorSmall }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarLeading) {
                Button("Undo", systemImage: "arrow.uturn.backward") { library.undoEdit() }
                    .disabled(!library.canUndoEdit)
                Button("Redo", systemImage: "arrow.uturn.forward") { library.redoEdit() }
                    .disabled(!library.canRedoEdit)
            }
            ToolbarItem {
                Button(library.isFilmstripShown ? "Hide Filmstrip" : "Show Filmstrip",
                       systemImage: "rectangle.bottomthird.inset.filled") {
                    library.isFilmstripShown.toggle()
                }
            }
            ToolbarItem {
                Button(library.isHistoryShown ? "Hide History" : "Show History",
                       systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                    library.isHistoryShown.toggle()
                }
                .disabled(!isEditable)
                .popover(isPresented: Binding(get: { sizeClass == .regular && library.isHistoryShown },
                                              set: { library.isHistoryShown = $0 })) {
                    history
                        // As tall as its steps, up to most of the screen, where it scrolls.
                        .frame(width: 320, height: min(CGFloat(HistorySidebar.rowCount(for: library)) * 52 + 100, 600))
                        .presentationCompactAdaptation(.popover)
                }
            }
            ToolbarItem {
                Button(library.isInspectorShown ? "Hide Adjustments" : "Show Adjustments",
                       systemImage: "slider.horizontal.3") {
                    library.isInspectorShown.toggle()
                }
            }
        }
    }

    private var history: some View {
        NavigationStack {
            HistorySidebar(library: library)
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if sizeClass == .compact {
                        // Close, not Done: a confirming button takes the highlight as a fill.
                        ToolbarItem(placement: .topBarTrailing) {
                            Button(role: .close) { library.isHistoryShown = false }
                        }
                    }
                }
        }
        // The iPhone inspector sheet's gray, rather than glass, as a sheet and as a popover.
        .scrollContentBackground(.hidden)
        .presentationBackground(Color.sheetBackground)
    }

    private var historySheet: some View {
        history.presentationDetents([.medium, .large])
    }

    /// History is a sheet in compact width, presented from the inspector's sheet while it is up,
    /// since a view under a presented sheet can't present another.
    private func compactHistory(whileSheetIsUp: Bool) -> Binding<Bool> {
        Binding(get: { sizeClass == .compact && library.isHistoryShown && (sheetTop != nil) == whileSheetIsUp },
                set: { library.isHistoryShown = $0 })
    }

    /// The sheet's heights: small and medium, or only small in landscape on a phone.
    private var sheetHeights: Set<PresentationDetent> {
        verticalSizeClass == .compact ? [.inspectorSmall] : [.inspectorSmall, .medium]
    }

    /// How much of the photo's space the inspector's sheet takes from the bottom.
    private var sheetInset: CGFloat {
        guard let sheetTop else { return 0 }
        return max(0, photoAreaBottom - sheetTop)
    }

    /// JPEG and HEIC photos, reached from the filmstrip, aren't edited until #239.
    private var isEditable: Bool { library.browse.selectedPhoto?.isEditable != false }

    @ViewBuilder private var photo: some View {
        if let renderer, let url = library.selectedPhotoURL {
            if library.browse.selectedPhoto?.isEditable == false {
                // Reached from the filmstrip; Edit doesn't open them until #239.
                ContentUnavailableView("Can't Edit This Photo Yet", systemImage: "photo",
                                       description: Text("Proof edits RAW photos. JPEG and HEIC photos can be rated and flagged in Browse."))
            } else if library.isSelectedPhotoInCloud {
                CloudPhotoPreview(url: url, backdrop: library.canvasColor.color)
                    .padding()
            } else {
                EditCanvas(library: library, url: url, renderer: renderer)
                    .padding()
            }
        } else if renderer == nil {
            ContentUnavailableView("Metal Isn't Available", systemImage: "exclamationmark.triangle",
                                   description: Text("Proof needs a device with a Metal GPU to show photos."))
        }
    }
}

/// The photo being edited, rendered with its current edit. A view of its own so it reads the
/// edit in its own body, and redraws on every change to it.
private struct EditCanvas: View {
    let library: Library
    let url: URL
    let renderer: RAWRenderer
    /// The photo has neither its render nor a cached thumbnail to show yet.
    @State private var isWaiting = false

    var body: some View {
        PhotoCanvas(url: url, renderer: renderer, recipe: shownRecipe, backdrop: library.canvasColor,
                    viewport: library.zoom.viewport, zoom: library.zoom, previews: ThumbnailCache.shared,
                    actions: actions) { error in
            library.errorMessage = "The photo couldn't be shown. (\(error))"
        } onHistogram: { histogram, url in
            library.showHistogram(histogram, of: url)
        } onWaiting: { isWaiting = $0 }
        // A temporary indicator, so it may sit where the photo will appear.
        .overlay {
            if isWaiting {
                ProgressView()
                    .accessibilityLabel("Loading photo")
            }
        }
        .accessibilityElement()
        .accessibilityLabel(library.windowTitle)
        .accessibilityValue(library.browse.isShowingOriginal ? "Original" : "")
        .accessibilityAddTraits(.isImage)
        .accessibilityAction(named: library.browse.isShowingOriginal ? "Show Edited" : "Show Original") {
            library.browse.toggleOriginal()
        }
        .accessibilityAction(named: "Next Photo") { step(.right) }
        .accessibilityAction(named: "Previous Photo") { step(.left) }
        // Each photo opens at Fit.
        .onAppear { library.zoom.reset() }
        .onChange(of: url) {
            library.zoom.reset()
            library.zoom.preview = nil
        }
    }

    private var shownRecipe: EditRecipe {
        let recipe = library.selectedEdit?.recipe ?? EditRecipe()
        return library.browse.isShowingOriginal ? recipe.original : recipe
    }

    private var actions: PhotoCanvasActions {
        PhotoCanvasActions(canSwipe: true) { isHeld in
            if isHeld != library.browse.isShowingOriginal { library.browse.toggleOriginal() }
        } swipe: { direction in
            step(direction == .left ? .right : .left)
        }
    }

    private func step(_ move: BrowseState.Move) {
        let photos = library.shownPhotos
        library.browse.move(move, in: photos, columns: photos.count)
    }
}

private extension PresentationDetent {
    /// The inspector sheet's small height on iPhone: the histogram and the start of the next card.
    static let inspectorSmall = PresentationDetent.height(220)
}
