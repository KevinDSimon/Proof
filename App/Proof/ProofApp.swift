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
            SidebarCommands()
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { library.requestFolder(.add) }
                    .keyboardShortcut("o")
            }
            CommandGroup(before: .sidebar) {
                Picker("Show", selection: $library.filter) {
                    Text("All Photos").tag(PhotoFilter.all)
                        .keyboardShortcut("1")
                    Text("5-Star Photos").tag(PhotoFilter.fiveStars)
                        .keyboardShortcut("2")
                    Text("Edited Photos").tag(PhotoFilter.edited)
                        .keyboardShortcut("3")
                }
                .pickerStyle(.inline)
                .disabled(library.selection == nil || library.isEditing)
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Button(library.isInspectorShown ? "Hide Inspector" : "Show Inspector") {
                    library.isInspectorShown.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(!library.isEditing)
            }
            CommandMenu("Photo") {
                Button("Edit") { library.browse.edit() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(library.isEditing || library.browse.selectedPhoto == nil)
                Button("Back to Folder") { library.browse.finishEditing() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(!library.isEditing)
            }
        }
    }
}

/// Browse shows the sidebar and a grid of the selected folder; Edit shows one photo on a plain
/// canvas with the inspector beside it. Panels sit next to the photo and never on top of it.
struct ContentView: View {
    @Bindable var library: Library
    @Environment(\.colorScheme) private var colorScheme
    @State private var renderer = try? RAWRenderer()
    @State private var exposure = 0.0
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    /// The sidebar's visibility in Browse, restored when Edit ends.
    @State private var browseColumnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            FolderSidebar(library: library)
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
                .toolbar(removing: library.isEditing ? .sidebarToggle : nil)
        } detail: {
            Group {
                if library.isEditing {
                    editor
                } else {
                    browser
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(white: PhotoCanvas.backdropGray(for: colorScheme)).ignoresSafeArea())
                }
            }
            .toolbarBand(gray: PhotoCanvas.backdropGray(for: colorScheme))
            .inspector(isPresented: Binding(get: { library.isEditing && library.isInspectorShown },
                                            set: { if library.isEditing { library.isInspectorShown = $0 } })) {
                AdjustmentsInspector(exposure: $exposure)
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
                    .toolbarBand(gray: PhotoCanvas.backdropGray(for: colorScheme))
            }
        }
        // Both modes follow the system appearance. The toolbar's own background and its separator
        // line are hidden: they would cut the sidebar and inspector dividers off at the toolbar
        // instead of letting them run to the top of the window. Each column draws its own band.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar {
            if library.isEditing {
                editToolbar
            } else {
                browseToolbar
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
        .onChange(of: library.browse.selectedPhoto) { exposure = 0 }
        .onChange(of: library.isEditing) { _, isEditing in
            if isEditing {
                browseColumnVisibility = columnVisibility
                columnVisibility = .detailOnly
            } else {
                columnVisibility = browseColumnVisibility
            }
        }
    }

    @ToolbarContentBuilder private var browseToolbar: some ToolbarContent {
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
    }

    @ToolbarContentBuilder private var editToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            // Esc reaches the window before the menu bar, so the button holds it as well as the Photo menu.
            Button("Back to Folder", systemImage: "chevron.backward") { library.browse.finishEditing() }
                .keyboardShortcut(.cancelAction)
                .help("Return to the folder")
        }
    }

    @ViewBuilder private var editor: some View {
        Group {
            if let renderer, let url = library.selectedPhotoURL {
                VStack(spacing: 0) {
                    PhotoCanvas(url: url, renderer: renderer, exposure: exposure,
                                backdropGray: PhotoCanvas.backdropGray(for: colorScheme)) { error in
                        library.errorMessage = "The photo couldn't be shown. (\(error))"
                    }
                    .padding(24)
                    if let folder = library.selection {
                        Filmstrip(library: library, folder: folder, photos: library.visiblePhotos)
                            .padding(.bottom, 8)
                    }
                }
            } else {
                ContentUnavailableView("Metal Isn't Available", systemImage: "exclamationmark.triangle",
                                       description: Text("Proof needs a Mac with a Metal GPU to show photos."))
            }
        }
        // The canvas runs under the toolbar glass and stops at the inspector; the photo stays inside the safe area.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Never under the inspector on the trailing edge: its material would show the gray through.
        .background(Color(white: PhotoCanvas.backdropGray(for: colorScheme))
            .ignoresSafeArea(edges: [.top, .leading, .bottom]))
        // Declared on the photo's column rather than the window, so the button sits over the
        // photo and stays put when the inspector opens and closes.
        .toolbar {
            ToolbarItem {
                Button("Inspector", systemImage: "sidebar.trailing") { library.isInspectorShown.toggle() }
                    .help(library.isInspectorShown ? "Hide the inspector" : "Show the inspector")
            }
        }
    }

    @ViewBuilder private var browser: some View {
        if library.locations.isEmpty {
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
                if let contents = library.contents[selection] {
                    if library.visiblePhotos.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "photo",
                                               description: Text("There are no RAW photos to show in this folder."))
                    } else {
                        ThumbnailGrid(library: library, folder: selection,
                                      photos: library.visiblePhotos, allPhotos: contents.photos)
                    }
                } else {
                    ProgressView()
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

    private var folderName: String? {
        guard let selection = library.selection else { return nil }
        return selection.relativePath.last ?? selectedLocation?.name
    }

    private var title: String {
        library.isEditing ? library.browse.selectedPhoto ?? "" : folderName ?? ""
    }

    /// In Browse, how many photos the folder has; in Edit, the folder and the photo's position.
    private var subtitle: String {
        guard let selection = library.selection, let contents = library.contents[selection] else { return "" }
        let visible = library.visiblePhotos
        if library.isEditing {
            let position = library.browse.position(in: visible).map { "\($0) of \(visible.count)" }
            // A saved location that is a single photo has no folder name to show.
            let folder = folderName == library.browse.selectedPhoto ? nil : folderName
            return [folder, position].compactMap { $0 }.joined(separator: " · ")
        }
        let total = contents.photos.count
        let noun = total == 1 ? "photo" : "photos"
        return library.filter == .all ? "\(total) \(noun)" : "\(visible.count) of \(total) \(noun)"
    }

    private var emptyTitle: String {
        switch library.filter {
        case .all: "No Photos"
        case .fiveStars: "No 5-Star Photos"
        case .edited: "No Edited Photos"
        }
    }
}

/// The adjustments for the photo being edited, in the trailing inspector. It sits on the same
/// plain color as the photo's canvas, so the panel and the photo read as one surface.
struct AdjustmentsInspector: View {
    @Binding var exposure: Double
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section("Light") {
                ExposureSlider(value: $exposure)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(white: PhotoCanvas.backdropGray(for: colorScheme)).ignoresSafeArea())
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
