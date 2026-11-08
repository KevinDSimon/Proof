import SwiftUI
import ProofKit

@main
struct ProofApp: App {
    @State private var library = Library()

    var body: some Scene {
        // One window, like other photo editors: the sidebar selection and filter belong to it.
        Window("Proof", id: "main") {
            ContentView(library: library)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { library.requestFolder(.add) }
                    .keyboardShortcut("o")
            }
        }
    }
}

/// The sidebar beside the photo on a dark canvas. Panels sit next to the photo and never on top of it.
struct ContentView: View {
    @Bindable var library: Library
    @State private var renderer = try? RAWRenderer()
    @State private var exposure = 0.0

    var body: some View {
        NavigationSplitView {
            FolderSidebar(library: library)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
        } detail: {
            // The gray runs under the toolbar glass; the photo itself stays inside the safe area.
            detail
                .padding(photoURL == nil ? 0 : 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PhotoCanvas.backdrop.ignoresSafeArea())
        }
        // Until Browse and Edit modes exist, the window is always viewing a photo, so it is dark
        // like Photos while editing. The toolbar's own background is hidden so the gray shows under its glass.
        .preferredColorScheme(.dark)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(photoName ?? folderName ?? "")
        .navigationSubtitle(subtitle)
        .toolbar {
            if library.selection != nil {
                ToolbarItem {
                    Picker("Filter", selection: $library.filter) {
                        Text("All").tag(PhotoFilter.all)
                        Text("5 Stars").tag(PhotoFilter.fiveStars)
                        Text("Edited").tag(PhotoFilter.edited)
                    }
                    .pickerStyle(.segmented)
                    .help("Show all photos in the folder, only 5-star photos, or only edited photos")
                }
            }
            if photoURL != nil {
                ToolbarSpacer(.fixed)
                ToolbarItem {
                    ExposureSlider(value: $exposure)
                }
            }
        }
        .fileImporter(isPresented: $library.isChoosingFolder, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): library.chose(url)
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .onChange(of: photoURL) { exposure = 0 }
    }

    @ViewBuilder private var detail: some View {
        if let renderer, let photoURL {
            PhotoCanvas(url: photoURL, renderer: renderer, exposure: exposure) { error in
                library.errorMessage = "The photo couldn't be shown. (\(error))"
            }
        } else if renderer == nil {
            ContentUnavailableView("Metal Isn't Available", systemImage: "exclamationmark.triangle",
                                   description: Text("Proof needs a Mac with a Metal GPU to show photos."))
        } else if library.locations.isEmpty {
            ContentUnavailableView {
                Label("No Folders", systemImage: "folder")
            } description: {
                Text("Add a folder of RAW photos to browse and edit them.")
            } actions: {
                Button("Add Folder…") { library.requestFolder(.add) }
            }
        } else if let selection = library.selection, let location = selectedLocation {
            switch library.status(of: selection.locationID) {
            case .missing:
                ContentUnavailableView {
                    Label("Folder Not Found", systemImage: "questionmark.folder")
                } description: {
                    Text("“\(location.name)” was moved or deleted. Locate it to see its photos again.")
                } actions: {
                    Button("Locate…") { library.requestFolder(.locate(location)) }
                }
            case .offline:
                ContentUnavailableView("Drive Not Connected", systemImage: "externaldrive.badge.xmark",
                                       description: Text("Connect the drive or network volume that holds “\(location.name)”."))
            case .available:
                if library.contents[selection] == nil {
                    ProgressView()
                } else {
                    ContentUnavailableView(emptyTitle, systemImage: "photo",
                                           description: Text("There are no RAW photos to show in this folder."))
                }
            }
        } else {
            ContentUnavailableView("No Folder Selected", systemImage: "sidebar.left",
                                   description: Text("Select a folder in the sidebar to see its photos."))
        }
    }

    private var selectedLocation: SavedLocation? {
        library.locations.first { $0.id == library.selection?.locationID }
    }

    /// Until the filmstrip arrives, the folder's first photo that passes the filter.
    private var photoURL: URL? {
        guard let selection = library.selection, let first = library.visiblePhotos.first else { return nil }
        return library.url(ofPhoto: first.name, in: selection)
    }

    private var photoName: String? {
        photoURL == nil ? nil : library.visiblePhotos.first?.name
    }

    private var folderName: String? {
        guard let selection = library.selection else { return nil }
        return selection.relativePath.last ?? selectedLocation?.name
    }

    private var subtitle: String {
        guard let selection = library.selection, let contents = library.contents[selection] else { return "" }
        let total = contents.photos.count
        let shown = library.visiblePhotos.count
        let noun = total == 1 ? "photo" : "photos"
        let count = library.filter == .all ? "\(total) \(noun)" : "\(shown) of \(total) \(noun)"
        return [photoName == nil ? nil : folderName, count].compactMap { $0 }.joined(separator: " · ")
    }

    private var emptyTitle: String {
        switch library.filter {
        case .all: "No Photos"
        case .fiveStars: "No 5-Star Photos"
        case .edited: "No Edited Photos"
        }
    }
}

/// Exposure in stops, −5 to +5, the range the edit format allows. Double-click the value to reset.
struct ExposureSlider: View {
    @Binding var value: Double

    var body: some View {
        HStack {
            Slider(value: $value, in: -5...5) {
                Text("Exposure")
            }
            .frame(width: 180)
            .accessibilityValue(String(format: "%+.2f stops", value))
            Text(value, format: .number.precision(.fractionLength(2)).sign(strategy: .always(includingZero: false)))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
                .onTapGesture(count: 2) { value = 0 }
                .help("Double-click to reset")
                .accessibilityHidden(true)
        }
    }
}
