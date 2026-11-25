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

/// The library beside the grid on iPad; on iPhone and in a narrow iPad window, a stack of
/// library, grid and photo, with the standard back button and edge swipe (decision 0048).
struct ContentView: View {
    @Bindable var library: Library
    /// With no folders the sidebar is empty, so iPhone opens on the empty state instead.
    @State private var compactColumn = NavigationSplitViewColumn.detail

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            FolderSidebar(library: library)
                .navigationTitle("Library")
        } detail: {
            NavigationStack {
                PhotoBrowser(library: library)
                    // On iPhone a row's grid is built before it slides in, while the library is
                    // still on screen, and isn't told when it appears, so its thumbnails never
                    // load. A grid of its own for each row is told.
                    .id(library.selection)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.interfaceBackground.ignoresSafeArea())
                    .navigationTitle(browseTitle)
                    .navigationSubtitle(browseSubtitle)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { browseToolbar }
                    // Select All takes the back button's place while selecting, as in Files.
                    .navigationBarBackButtonHidden(library.isSelectingPhotos)
                    .navigationDestination(isPresented: isEditing) {
                        PhotoView(library: library)
                    }
            }
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
        // Folders that were added open on the library, so they can be seen; with none, the empty state.
        .onChange(of: library.locations.isEmpty, initial: true) { _, isEmpty in
            compactColumn = isEmpty ? .detail : .sidebar
        }
    }

    /// Browse has one More menu, with Select and the filter, so the bar stays clear on iPhone.
    /// While selecting, the bar has Select All and Done, and a bottom toolbar rates and flags the
    /// selected photos, as in Files and Photos.
    @ToolbarContentBuilder private var browseToolbar: some ToolbarContent {
        if library.isSelectingPhotos {
            let allSelected = library.browse.selectedPhotos.count == library.shownPhotos.count
            ToolbarItem(placement: .topBarLeading) {
                Button(allSelected ? "Deselect All" : "Select All") {
                    if allSelected { library.deselectAll() } else { library.browse.selectAll(library.shownPhotos) }
                }
            }
            ToolbarItem { Button("Done") { library.isSelectingPhotos = false } }
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
                Menu("More", systemImage: "ellipsis") {
                    Button("Select", systemImage: "checkmark.circle") { library.isSelectingPhotos = true }
                        .disabled(library.visiblePhotos.isEmpty)
                    Menu {
                        FilterMenu(library: library)
                    } label: {
                        Label("Filter", systemImage: "line.3.horizontal.decrease")
                        if !library.filter.isEmpty { Text(library.filter.summary) }
                    }
                }
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
        return switch count {
        case 0: "Select Photos"
        case 1: "1 Photo Selected"
        default: "\(count) Photos Selected"
        }
    }
    /// The filter's name follows the count, as the filter button has no badge on iOS.
    private var browseSubtitle: String {
        guard !library.isEditing else { return "" }
        let filter = library.filter.isEmpty || library.isSelectingPhotos ? nil : library.filter.summary
        return [library.windowSubtitle, filter].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
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
