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
            // Undo steps through the edit of the photo open in Edit; Browse has nothing to undo.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { library.undoEdit() }
                    .keyboardShortcut("z")
                    .disabled(!library.isEditing || !library.canUndoEdit)
                Button("Redo") { library.redoEdit() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!library.isEditing || !library.canRedoEdit)
            }
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { library.requestFolder(.add) }
                    .keyboardShortcut("o")
            }
            CommandGroup(before: .sidebar) {
                // In Edit, ⌘1 is Actual Size instead.
                Picker("Show", selection: $library.filter) {
                    Text("All").tag(PhotoFilter.all)
                        .keyboardShortcut(library.isEditing ? nil : KeyboardShortcut("1"))
                    Text("5-Star Photos").tag(PhotoFilter.fiveStars)
                        .keyboardShortcut(library.isEditing ? nil : KeyboardShortcut("2"))
                    Text("Edited Photos").tag(PhotoFilter.edited)
                        .keyboardShortcut(library.isEditing ? nil : KeyboardShortcut("3"))
                }
                .pickerStyle(.inline)
                .disabled(library.selection == nil || library.isEditing)
                Divider()
                Button("Reload Folders") { library.refresh() }
                    .keyboardShortcut("r")
                    .disabled(library.locations.isEmpty || library.isEditing)
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Button(library.isInspectorShown ? "Hide Inspector" : "Show Inspector") {
                    library.isInspectorShown.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(!library.isEditing)
                Divider()
                Button("Zoom In") { library.zoom.zoomIn() }
                    .keyboardShortcut("+")
                    .disabled(!library.isEditing || !library.zoom.canZoomIn)
                Button("Zoom Out") { library.zoom.zoomOut() }
                    .keyboardShortcut("-")
                    .disabled(!library.isEditing || !library.zoom.canZoomOut)
                Button("Zoom to Fit") { library.zoom.zoom(to: nil) }
                    .keyboardShortcut("0")
                    .disabled(!library.isEditing || !library.zoom.isEnabled || library.zoom.viewport.isFit)
                Button("Actual Size") { library.zoom.zoom(to: 1) }
                    .keyboardShortcut(library.isEditing ? KeyboardShortcut("1") : nil)
                    .disabled(!library.isEditing || !library.zoom.isEnabled || library.zoom.viewport.scale == 1)
            }
            CommandMenu("Photo") {
                Button("Edit") { library.browse.edit() }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(library.isEditing || library.browse.selectedPhoto == nil)
                // While cropping, Esc cancels the crop instead.
                Button("Back to Folder") { library.browse.finishEditing() }
                    .keyboardShortcut(library.isCropping ? nil : KeyboardShortcut(.escape, modifiers: []))
                    .disabled(!library.isEditing)
                Button("Revert to Original") { library.revertEdit() }
                    .disabled(!library.isEditing || !library.canRevertEdit)
                Divider()
                // C opens and closes the crop tool, as R does in Lightroom's.
                if library.isCropping {
                    Button("Done Cropping") { library.finishCropping() }
                        .keyboardShortcut(.return, modifiers: [])
                    Button("Cancel Cropping") { library.cancelCropping() }
                        .keyboardShortcut(.escape, modifiers: [])
                    Button("Swap Crop Orientation") { library.swapCropOrientation() }
                        .keyboardShortcut("x", modifiers: [])
                } else {
                    Button("Crop") { library.startCropping() }
                        .keyboardShortcut("c", modifiers: [])
                        .disabled(!library.isEditing || library.selectedEdit == nil)
                }
                Button("Rotate Left") { library.rotate(clockwise: false) }
                    .keyboardShortcut("[")
                    .disabled(!library.isEditing || library.selectedEdit == nil)
                Button("Rotate Right") { library.rotate(clockwise: true) }
                    .keyboardShortcut("]")
                    .disabled(!library.isEditing || library.selectedEdit == nil)
                Button("Flip Horizontal") { library.flipHorizontally() }
                    .disabled(!library.isEditing || library.selectedEdit == nil)
                Button("Flip Vertical") { library.flipVertically() }
                    .disabled(!library.isEditing || library.selectedEdit == nil)
                Divider()
                // Steps through the looks in the folder the Looks section shows, to compare them.
                Button("Next Look") { library.stepLook(by: 1) }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(!library.canStepLook)
                Button("Previous Look") { library.stepLook(by: -1) }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(!library.canStepLook)
                Divider()
                // Lightroom's keys: 0 to 5 for stars, P, U and X for the flag.
                Picker("Rating", selection: Binding(get: { library.selectedPhotoMetadata?.rating ?? 0 },
                                                    set: { library.setRating($0) })) {
                    ForEach(0...5, id: \.self) { rating in
                        Text(RatingBadges.title(ofRating: rating)).tag(rating)
                            .keyboardShortcut(KeyEquivalent(Character("\(rating)")), modifiers: [])
                    }
                }
                .pickerStyle(.inline)
                .disabled(library.browse.selectedPhoto == nil)
                Divider()
                Picker("Flag", selection: Binding(get: { library.selectedPhotoMetadata?.flag ?? .unflagged },
                                                  set: { library.setFlag($0) })) {
                    Text("Flagged").tag(PhotoMetadata.Flag.flagged).keyboardShortcut("p", modifiers: [])
                    Text("Unflagged").tag(PhotoMetadata.Flag.unflagged).keyboardShortcut("u", modifiers: [])
                    // While cropping, X swaps the crop's orientation instead, as in Lightroom.
                    Text("Rejected").tag(PhotoMetadata.Flag.rejected)
                        .keyboardShortcut(library.isCropping ? nil : KeyboardShortcut("x", modifiers: []))
                }
                .pickerStyle(.inline)
                .disabled(library.browse.selectedPhoto == nil)
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
            .inspector(isPresented: Binding(get: { library.isEditing && library.isInspectorShown },
                                            set: { if library.isEditing { library.isInspectorShown = $0 } })) {
                Group {
                    if library.isCropping {
                        CropInspector(library: library, renderer: renderer)
                    } else {
                        AdjustmentsInspector(library: library)
                    }
                }
                .inspectorColumnWidth(min: 240, ideal: 280, max: 360)
            }
        }
        // Both modes follow the system appearance. The toolbar keeps the system's default
        // background and scroll edge effect, which keep the title readable over scrolled content.
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
        .fileDialogDefaultDirectory(library.folderPickerDirectory)
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
                .keyboardShortcut(library.isCropping ? nil : .cancelAction)
                .help("Return to the folder")
        }
    }

    @ViewBuilder private var editor: some View {
        Group {
            if let renderer, let url = library.selectedPhotoURL {
                VStack(spacing: 0) {
                    // More margin while cropping, so the handles clear the window's edges.
                    EditCanvas(library: library, url: url, renderer: renderer)
                        .padding(library.isCropping ? 40 : 24)
                    Filmstrip(library: library, photos: library.visiblePhotos)
                        .padding(.bottom, 8)
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
                ZoomMenu(zoom: library.zoom)
            }
            ToolbarSpacer(.fixed)
            // Stars and flags are separate groups, as in Lightroom, at the trailing end so the
            // title stands on its own.
            ToolbarItem {
                StarButtons(rating: library.selectedPhotoMetadata?.rating ?? 0, setRating: library.setRating)
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                FlagButtons(flag: library.selectedPhotoMetadata?.flag ?? .unflagged, setFlag: library.setFlag)
            }
            ToolbarSpacer(.fixed)
            if library.isCropping {
                ToolbarItemGroup {
                    // Esc reaches the window before the menu bar, so the button holds it as well as the Photo menu.
                    Button("Cancel") { library.cancelCropping() }
                        .keyboardShortcut(.cancelAction)
                        .help("Return to the crop from before the tool opened (Esc)")
                    Button("Done") { library.finishCropping() }
                        .keyboardShortcut(.return, modifiers: [])
                        .help("Keep the crop (Return)")
                }
            } else {
                ToolbarItem {
                    Button("Crop", systemImage: "crop") { library.startCropping() }
                        .help("Crop, straighten, rotate and flip the photo (C)")
                        .disabled(library.selectedEdit == nil)
                }
            }
            // The crop tool and the inspector are separate groups.
            ToolbarSpacer(.fixed)
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
        } else if library.selection == .allPhotos {
            allPhotos
        } else if let selection = library.selection?.folder, let location = selectedLocation {
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
                if library.contents[selection] != nil {
                    if library.visiblePhotos.isEmpty {
                        ContentUnavailableView(emptyTitle, systemImage: "photo",
                                               description: Text("There are no RAW photos to show in this folder."))
                    } else {
                        ThumbnailGrid(library: library, photos: library.visiblePhotos, allPhotos: library.listedPhotos)
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

    /// Photos from every available location. Locations that can't be reached are left out, and
    /// the subtitle names them.
    @ViewBuilder private var allPhotos: some View {
        if library.unavailableLocations.count == library.locations.count {
            ContentUnavailableView("No Folders Available", systemImage: "externaldrive.badge.xmark",
                                   description: Text("Connect the drives or network volumes that hold your folders."))
        } else if !library.visiblePhotos.isEmpty {
            ThumbnailGrid(library: library, photos: library.visiblePhotos, allPhotos: library.listedPhotos)
        } else if library.isReadingAllPhotos {
            ProgressView()
        } else {
            ContentUnavailableView(emptyTitle, systemImage: "photo",
                                   description: Text("There are no RAW photos to show in your folders."))
        }
    }

    private var selectedLocation: SavedLocation? {
        library.locations.first { $0.id == library.selection?.folder?.locationID }
    }

    private var title: String {
        if library.isEditing { return library.browse.selectedPhoto?.name ?? "" }
        switch library.selection {
        case .allPhotos: return "All Photos"
        case .folder(let folder): return library.name(of: folder)
        case nil: return ""
        }
    }

    /// In Browse, how many photos are shown, and for All Photos which locations are left out; in
    /// Edit, the photo's folder and its position.
    private var subtitle: String {
        let visible = library.visiblePhotos
        if library.isEditing {
            let position = library.browse.position(in: visible).map { "\($0) of \(visible.count)" }
            // A saved location that is a single photo has no folder name to show.
            let folder = library.browse.selectedPhoto.map { library.name(of: $0.folder) }
            let shownFolder = folder == library.browse.selectedPhoto?.name ? nil : folder
            return [shownFolder, position].compactMap { $0 }.joined(separator: " · ")
        }
        if let folder = library.selection?.folder, library.contents[folder] == nil { return "" }
        if library.selection == nil { return "" }
        let total = library.listedPhotos.count
        let noun = total == 1 ? "photo" : "photos"
        let count = library.filter == .all ? "\(total) \(noun)" : "\(visible.count) of \(total) \(noun)"
        let unavailable = library.unavailableLocations
        guard library.selection == .allPhotos, !unavailable.isEmpty else { return count }
        let missing = unavailable.count == 1 ? "“\(unavailable[0].name)” isn't available"
                                             : "\(unavailable.count) folders aren't available"
        return "\(count) · \(missing)"
    }

    private var emptyTitle: String {
        switch library.filter {
        case .all: "No Photos"
        case .fiveStars: "No 5-Star Photos"
        case .edited: "No Edited Photos"
        }
    }
}

/// The photo being edited, rendered with its current edit. A view of its own so it reads the
/// edit in its own body, and redraws on every change to it, including during a drag.
struct EditCanvas: View {
    let library: Library
    let url: URL
    let renderer: RAWRenderer
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let backdrop = PhotoCanvas.backdropGray(for: colorScheme)
        PhotoCanvas(url: url, renderer: renderer, recipe: shownRecipe, backdropGray: backdrop,
                    angle: library.isCropping ? library.selectedCrop.angle : 0,
                    viewport: library.zoom.viewport, zoom: library.zoom) { error in
            library.errorMessage = "The photo couldn't be shown. (\(error))"
        } onHistogram: { histogram, url in
            library.showHistogram(histogram, of: url)
        }
        .overlay {
            if library.isCropping, let frame = library.selectedCropFrame {
                CropOverlay(library: library, frame: frame, aspect: library.selectedCrop.aspect, backdropGray: backdrop)
            }
        }
        // Each photo opens at Fit. The crop tool shows the whole photo, so zoom is off while it's open.
        .onAppear { library.zoom.reset() }
        .onChange(of: url) { library.zoom.reset() }
        .onChange(of: library.isCropping, initial: true) { _, isCropping in
            library.zoom.isEnabled = !isCropping
            if isCropping { library.zoom.reset() }
        }
    }

    /// While cropping, the whole photo, turned and flipped: the canvas tilts it and the overlay
    /// marks the rectangle, so a drag doesn't wait for a render.
    private var shownRecipe: EditRecipe {
        var recipe = library.selectedEdit?.recipe ?? EditRecipe()
        if library.isCropping { recipe.crop = recipe.crop?.turnedOnly }
        if library.isCurveHidden { recipe.curve = ToneCurve() }
        if library.isLookHidden { recipe.look = nil }
        return recipe
    }
}

/// The toolbar's zoom pop-up: the current zoom as its title, and Fit and the steps to choose from.
private struct ZoomMenu: View {
    let zoom: CanvasZoom

    var body: some View {
        Menu {
            Picker("Zoom", selection: Binding(get: { zoom.viewport.scale }, set: { zoom.zoom(to: $0) })) {
                Text("Fit").tag(Double?.none)
                ForEach(Viewport.steps, id: \.self) { step in
                    Text(CanvasZoom.title(of: step)).tag(Double?.some(step))
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            Text(zoom.title)
                .monospacedDigit()
        }
        .menuIndicator(.visible)
        .fixedSize()
        .disabled(!zoom.isEnabled)
        .help("Zoom (⌘+, ⌘−, ⌘0 to fit, ⌘1 for actual size)")
        .accessibilityLabel("Zoom")
        .accessibilityValue(zoom.title)
    }
}

/// Reads the histogram in its own body, so a new one redraws only the graph, not the inspector.
private struct SelectedHistogram: View {
    let library: Library

    var body: some View {
        HistogramView(histogram: library.selectedHistogram)
            .equatable()
    }
}

/// The adjustments for the photo being edited, in the trailing inspector. It sits on the same
/// plain color as the photo's canvas, so the panel and the photo read as one surface.
struct AdjustmentsInspector: View {
    let library: Library

    var body: some View {
        Form {
            Section {
                SelectedHistogram(library: library)
            } header: {
                SectionTitle("Histogram")
            } footer: {
                CaptureSettingsLine(settings: library.selectedEdit?.captureSettings)
            }
            Section {
                // A full-width pop-up, as in Finder's settings; Custom is listed only while it is chosen.
                MenuPopUp(title: Self.title(of: basic.whiteBalance),
                          items: WhiteBalancePreset.allCases
                              .filter { $0 != .custom || basic.whiteBalance == .custom }
                              .map { preset in
                                  .action(Self.title(of: preset), isChecked: preset == basic.whiteBalance) {
                                      library.changeEdit { $0.basic.choose(preset) }
                                  }
                              })
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel("White Balance Preset")
                AdjustmentSlider(
                    title: "Temperature",
                    value: Binding(get: { shown.temperature },
                                   set: { kelvin in library.changeEdit { $0.basic.setTemperature(kelvin) } }),
                    range: WhiteBalance.temperatureRange, fineStep: 1, step: 10, coarseStep: 100, fractionDigits: 0,
                    unit: "Kelvin", track: Self.temperatureTrack,
                    position: WhiteBalance.sliderPosition(forTemperature:),
                    valueAtPosition: WhiteBalance.temperature(atSliderPosition:),
                    reset: { library.changeEdit { $0.basic.resetTemperature() } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Tint",
                    value: Binding(get: { shown.tint },
                                   set: { tint in library.changeEdit { $0.basic.setTint(tint) } }),
                    range: WhiteBalance.tintRange, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.tintTrack,
                    reset: { library.changeEdit { $0.basic.resetTint() } },
                    isAdjusting: { library.isAdjusting = $0 })
            } header: {
                SectionHeader(title: "White Balance", canReset: basic.whiteBalance != .asShot) {
                    library.changeEdit { $0.basic.resetWhiteBalance() }
                }
            }
            // White balance can't be shown until the camera's has been read from the photo.
            .disabled(library.selectedEdit?.asShot == nil)
            Section {
                AdjustmentSlider(
                    title: "Exposure",
                    value: Binding(get: { basic.exposure },
                                   set: { value in library.changeEdit { $0.basic.exposure = value } }),
                    range: -5...5, fineStep: 0.01, step: 0.1, coarseStep: 1, fractionDigits: 2,
                    showsSign: true, unit: "stops", track: Self.exposureTrack,
                    reset: { library.changeEdit { $0.basic.exposure = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Contrast",
                    value: Binding(get: { basic.contrast },
                                   set: { value in library.changeEdit { $0.basic.contrast = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.contrastTrack,
                    reset: { library.changeEdit { $0.basic.contrast = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Highlights",
                    value: Binding(get: { basic.highlights },
                                   set: { value in library.changeEdit { $0.basic.highlights = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.highlightsTrack,
                    reset: { library.changeEdit { $0.basic.highlights = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Shadows",
                    value: Binding(get: { basic.shadows },
                                   set: { value in library.changeEdit { $0.basic.shadows = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.shadowsTrack,
                    reset: { library.changeEdit { $0.basic.shadows = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Whites",
                    value: Binding(get: { basic.whites },
                                   set: { value in library.changeEdit { $0.basic.whites = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.whitesTrack,
                    reset: { library.changeEdit { $0.basic.whites = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Blacks",
                    value: Binding(get: { basic.blacks },
                                   set: { value in library.changeEdit { $0.basic.blacks = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.blacksTrack,
                    reset: { library.changeEdit { $0.basic.blacks = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
            } header: {
                SectionHeader(title: "Light", canReset: basic.exposure != 0 || basic.contrast != 0 || basic.highlights != 0
                              || basic.shadows != 0 || basic.whites != 0 || basic.blacks != 0) {
                    library.changeEdit {
                        $0.basic.exposure = 0
                        $0.basic.contrast = 0
                        $0.basic.highlights = 0
                        $0.basic.shadows = 0
                        $0.basic.whites = 0
                        $0.basic.blacks = 0
                    }
                }
            }
            .disabled(library.selectedEdit == nil)
            Section {
                AdjustmentSlider(
                    title: "Vibrance",
                    value: Binding(get: { basic.vibrance },
                                   set: { value in library.changeEdit { $0.basic.vibrance = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.vibranceTrack,
                    reset: { library.changeEdit { $0.basic.vibrance = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Saturation",
                    value: Binding(get: { basic.saturation },
                                   set: { value in library.changeEdit { $0.basic.saturation = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.saturationTrack,
                    reset: { library.changeEdit { $0.basic.saturation = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
            } header: {
                SectionHeader(title: "Color", canReset: basic.vibrance != 0 || basic.saturation != 0) {
                    library.changeEdit {
                        $0.basic.vibrance = 0
                        $0.basic.saturation = 0
                    }
                }
            }
            .disabled(library.selectedEdit == nil)
            Section {
                CurveEditor(library: library)
                    .opacity(library.isCurveHidden ? 0.45 : 1)
            } header: {
                let hasCurve = !(library.selectedEdit?.recipe.curve.isIdentity ?? true)
                SectionHeader(title: "Curve", canReset: hasCurve,
                              isOn: Binding(get: { !library.isCurveHidden }, set: { library.isCurveHidden = !$0 }),
                              canToggle: hasCurve) {
                    library.isCurveHidden = false
                    library.changeEdit { $0.curve = ToneCurve() }
                }
            }
            .disabled(library.selectedEdit == nil)
            LookSection(library: library)
            if let unsaved = library.selectedEdit?.unsaved {
                Section {
                    Text(Self.message(for: unsaved))
                        .foregroundStyle(.secondary)
                    if unsaved == .noAccess {
                        Button("Grant Access…") { library.grantWriteAccessForSelectedPhoto() }
                    }
                }
            }
        }
        .inspectorForm()
    }

    private var basic: BasicAdjustments { library.selectedEdit?.recipe.basic ?? BasicAdjustments() }

    /// The white balance the photo shows, the camera's where it hasn't been changed.
    private var shown: WhiteBalance {
        basic.whiteBalance(asShot: library.selectedEdit?.asShot ?? WhiteBalance(temperature: 5500, tint: 0))
    }

    /// Blue to yellow and green to magenta, the way each slider shifts the photo. These show the
    /// photo's colors, so they are the one place the inspector isn't gray. Each color fades out
    /// toward the middle rather than blending into the other: opposite colors blend to gray,
    /// which reads as a dark band. The faded middle takes the panel's color in either appearance.
    private static let temperatureTrack = fading(Color(red: 0.25, green: 0.45, blue: 0.95), into: Color(red: 0.95, green: 0.8, blue: 0.2))
    private static let tintTrack = fading(Color(red: 0.25, green: 0.7, blue: 0.3), into: Color(red: 0.85, green: 0.3, blue: 0.8))
    /// Dark to light, the way exposure moves the photo.
    /// Starts at pure black because the system slider's own groove, drawn over it, lightens it.
    private static let exposureTrack = [Color(white: 0), Color(white: 0.97)]
    /// The other tone sliders run dark to light end to end too, as Lightroom draws them.
    private static let contrastTrack = exposureTrack
    private static let highlightsTrack = exposureTrack
    private static let shadowsTrack = exposureTrack
    private static let whitesTrack = exposureTrack
    private static let blacksTrack = exposureTrack
    /// Gray to a full spectrum, teal through blue and magenta to red, growing more colorful
    /// toward the right. A single color would suggest the slider pushes the photo toward it.
    private static let vibranceTrack = [
        Color(white: 0.5),
        Color(hue: 0.47, saturation: 0.3, brightness: 0.7),
        Color(hue: 0.6, saturation: 0.6, brightness: 0.85),
        Color(hue: 0.83, saturation: 0.75, brightness: 0.9),
        Color(hue: 1, saturation: 0.85, brightness: 0.95),
    ]
    private static let saturationTrack = vibranceTrack

    private static func fading(_ start: Color, into end: Color) -> [Color] {
        [start, start.opacity(0.15), end.opacity(0.15), end]
    }

    private static func title(of preset: WhiteBalancePreset) -> String {
        switch preset {
        case .asShot: "As Shot"
        case .daylight: "Daylight"
        case .cloudy: "Cloudy"
        case .shade: "Shade"
        case .tungsten: "Tungsten"
        case .fluorescent: "Fluorescent"
        case .flash: "Flash"
        case .custom: "Custom"
        }
    }

    private static func message(for unsaved: PhotoEdit.Unsaved) -> String {
        switch unsaved {
        case .noAccess: "Not saved. Proof needs permission to save edits in this photo's folder."
        case .unreadable: "This photo's edit file couldn't be read, so changes aren't saved."
        case .failed: "The last change couldn't be saved."
        }
    }
}

/// A section title with a Reset button that returns the section's adjustments to none, and
/// optionally a switch that shows the photo with and without the section's adjustments.
struct SectionHeader: View {
    let title: String
    let canReset: Bool
    var isOn: Binding<Bool>?
    var canToggle = true
    let reset: () -> Void

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button("Reset", action: reset)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(!canReset)
                .accessibilityLabel("Reset \(title)")
            if let isOn {
                Toggle(title, isOn: isOn)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    // Green, as on iPhone and iPad: without a tint the switch is white either
                    // way, and on and off are hard to tell apart.
                    .tint(.green)
                    .labelsHidden()
                    .disabled(!canToggle)
                    .help(isOn.wrappedValue ? "Hide this adjustment to compare" : "Show this adjustment")
                    .accessibilityLabel("Show \(title)")
            }
        }
        .padding(.top, SectionTitle.spacing)
    }
}

/// A section header with no Reset button, spaced like `SectionHeader`.
struct SectionTitle: View {
    /// Extra space above each header, which is what separates the inspector's sections.
    static let spacing: CGFloat = 14
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .padding(.top, Self.spacing)
    }
}
