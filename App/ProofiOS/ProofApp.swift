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
                    .toolbar {
                        // Only in Browse, and only once a row is picked, as on the Mac.
                        if library.selection != nil, !library.isEditing {
                            ToolbarItem { FilterButton(library: library) }
                        }
                    }
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
        // Folders that were added open on the library, so they can be seen; with none, the empty state.
        .onChange(of: library.locations.isEmpty, initial: true) { _, isEmpty in
            compactColumn = isEmpty ? .detail : .sidebar
        }
    }

    /// Going back from the photo, by the back button or the edge swipe, returns to Browse.
    private var isEditing: Binding<Bool> {
        Binding(get: { library.isEditing },
                set: { if !$0, library.isEditing { library.browse.finishEditing() } })
    }

    // The grid's title stays the row's while the photo is pushed, so the back button names it.
    private var browseTitle: String { library.rowTitle }
    private var browseSubtitle: String { library.isEditing ? "" : library.windowSubtitle }
}

/// The photo, centered on the canvas with a margin. Its thumbnail stands in until the edit
/// canvas, with zoom, pan and the filmstrip, comes in #226.
private struct PhotoView: View {
    let library: Library
    @State private var image: CGImage?

    var body: some View {
        let photo = library.browse.selectedPhoto
        ZStack {
            Color.interfaceBackground.ignoresSafeArea()
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .padding()
            } else {
                ProgressView()
            }
        }
        .navigationTitle(library.windowTitle)
        .navigationSubtitle(library.windowSubtitle)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: photo) {
            image = nil
            guard let photo, let url = library.url(ofPhoto: photo.name, in: photo.folder) else { return }
            image = await ThumbnailCache.shared.thumbnail(for: url, edit: nil)
        }
    }
}
