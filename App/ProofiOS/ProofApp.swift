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

    var body: some View {
        Group {
            if sizeClass == .compact { compactStack } else { splitView }
        }
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
        .onChange(of: library.isEditing) { if library.isEditing { library.isSelectingPhotos = false } }
    }

    private var splitView: some View {
        NavigationSplitView {
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
                PhotoView(library: library)
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
        // As in Notes; the count of photos is under the grid.
        return count == 0 ? "Select Photos" : "\(count) Selected"
    }
}

private extension View {
    /// A yellow badge counting the filter parts that are set, on the button that holds the
    /// filter, since the count under the grid may be out of sight. The system's toolbar badge
    /// is always red (decision 0041).
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

/// The photo, centered on the canvas with a margin. Its thumbnail stands in until the edit
/// canvas, with zoom, pan and the filmstrip, comes in #226.
private struct PhotoView: View {
    let library: Library
    @State private var image: CGImage?

    var body: some View {
        let photo = library.browse.selectedPhoto
        // A photo in iCloud shows the system's thumbnail while it downloads, then its own
        // (decision 0050).
        let isInCloud = photo.flatMap { photo in
            library.contents[photo.folder]?.photos.first { $0.name == photo.name }?.isInCloud
        } ?? false
        ZStack {
            Color.interfaceBackground.ignoresSafeArea()
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding()
                    .overlay {
                        if isInCloud { downloading }
                    }
            } else if isInCloud {
                downloading
            } else {
                ProgressView()
            }
        }
        .navigationTitle(library.windowTitle)
        .navigationSubtitle(library.windowSubtitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: PhotoLoad(photo: photo, isInCloud: isInCloud)) {
            image = nil
            guard let photo, let url = library.url(ofPhoto: photo.name, in: photo.folder) else { return }
            image = await ThumbnailCache.shared.thumbnail(for: url, edit: nil)
        }
    }
}

private extension PhotoView {
    var downloading: some View {
        ProgressView("Downloading from iCloud…")
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
    }
}

/// What the photo screen loads: the photo, again once it has downloaded from iCloud.
private struct PhotoLoad: Hashable {
    var photo: PhotoReference?
    var isInCloud: Bool
}
