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
                    .keyboardShortcut(library.isCropping || library.isPickingWhiteBalance
                                      ? nil : KeyboardShortcut(.escape, modifiers: []))
                    .disabled(!library.isEditing)
                Button("Revert to Original") { library.revertEdit() }
                    .disabled(!library.isEditing || !library.canRevertEdit)
                // Backslash, as in Lightroom. A toggle, so the menu marks it while the original shows.
                Toggle("Show Original", isOn: Binding(get: { library.browse.isShowingOriginal },
                                                      set: { _ in library.toggleOriginal() }))
                    .keyboardShortcut("\\", modifiers: [])
                    .disabled(!library.isEditing || library.isCropping || library.isPickingWhiteBalance
                              || library.selectedEdit == nil)
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
                // W, as in Lightroom; while it's open, Esc closes it instead of leaving Edit.
                if library.isPickingWhiteBalance {
                    Button("Cancel White Balance Selector") { library.isPickingWhiteBalance = false }
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button("White Balance Selector") { library.toggleWhiteBalancePicker() }
                        .keyboardShortcut("w", modifiers: [])
                        .disabled(!library.isEditing || library.isCropping || library.selectedEdit?.asShot == nil)
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
                        AdjustmentsInspector(library: library, renderer: renderer)
                    }
                }
                // Wide enough at its narrowest for the longest card header, "Lens Corrections" beside Reset and its switch.
                .inspectorColumnWidth(min: 300, ideal: 320, max: 420)
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
                .keyboardShortcut(library.isCropping || library.isPickingWhiteBalance ? nil : .cancelAction)
                .help("Return to the folder")
        }
    }

    @ViewBuilder private var editor: some View {
        Group {
            if let renderer, let url = library.selectedPhotoURL {
                VStack(spacing: 0) {
                    // The same margin while cropping, so the photo doesn't shrink when the tool opens: the
                    // handles are drawn inside the crop border, and their 12 pt reach fits in 24.
                    EditCanvas(library: library, url: url, renderer: renderer)
                        .padding(24)
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
            // Just left of the crop tool, with the navigator below it while zoomed.
            ToolbarItem {
                ZoomMenu(zoom: library.zoom)
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
    /// Edit, the photo's folder and its position, after "Original" while backslash shows it.
    private var subtitle: String {
        let visible = library.visiblePhotos
        if library.isEditing {
            let position = library.browse.position(in: visible).map { "\($0) of \(visible.count)" }
            // A saved location that is a single photo has no folder name to show.
            let folder = library.browse.selectedPhoto.map { library.name(of: $0.folder) }
            let shownFolder = folder == library.browse.selectedPhoto?.name ? nil : folder
            let original = library.browse.isShowingOriginal ? "Original" : nil
            return [original, shownFolder, position].compactMap { $0 }.joined(separator: " · ")
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
            } else if library.isPickingWhiteBalance {
                WhiteBalancePicker(library: library, renderer: renderer)
            } else if library.isDrawingGuides, let size = library.selectedEdit?.size {
                GuideOverlay(library: library, zoom: library.zoom, transform: shownRecipe.transform, photoSize: size)
            } else if library.isAdjustingGeometry {
                DistortionGrid(zoom: library.zoom)
            }
        }
        // A temporary tool, so it may sit on the photo: only while zoomed, in the corner under the
        // toolbar's zoom pop-up.
        .overlay(alignment: .topTrailing) {
            if let preview = library.zoom.preview, library.zoom.isEnabled, library.zoom.canPan {
                Navigator(zoom: library.zoom, preview: preview, backdropGray: backdrop)
                    .padding(12)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: library.zoom.canPan)
        // Each photo opens at Fit.
        .onAppear { library.zoom.reset() }
        .onChange(of: url) {
            library.zoom.reset()
            library.zoom.preview = nil
        }
        // The crop tool and Guided show the whole photo, so zoom is off while either is open.
        .onChange(of: library.isCropping || library.isDrawingGuides, initial: true) { _, isWhole in
            library.zoom.isEnabled = !isWhole
            if isWhole { library.zoom.reset() }
        }
    }

    /// While cropping, the whole photo, turned and flipped: the canvas tilts it and the overlay
    /// marks the rectangle, so a drag doesn't wait for a render.
    private var shownRecipe: EditRecipe {
        var recipe = library.selectedEdit?.recipe ?? EditRecipe()
        if library.browse.isShowingOriginal { return recipe.original }
        if library.isCropping { recipe.crop = recipe.crop?.turnedOnly }
        // Guided shows the whole photo as the camera oriented it, the space guides are drawn in.
        if library.isDrawingGuides { recipe.crop = nil }
        return recipe.without(library.offGroups)
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
    let renderer: RAWRenderer?

    var body: some View {
        InspectorPanel {
            InspectorCard(title: "Histogram") {
                SelectedHistogram(library: library)
                CaptureSettingsLine(settings: library.selectedEdit?.captureSettings)
            }
            InspectorCard(title: "White Balance", isOn: library.isOnBinding(.whiteBalance),
                          canReset: basic.whiteBalance != .asShot,
                          reset: { library.changeEdit { $0.basic.resetWhiteBalance() } }) {
                // The eyedropper after the pop-up; Custom is listed only while it is chosen.
                HStack {
                    MenuPopUp(title: Self.title(of: basic.whiteBalance),
                              items: WhiteBalancePreset.allCases
                                  .filter { $0 != .custom || basic.whiteBalance == .custom }
                                  .map { preset in
                                      .action(Self.title(of: preset), isChecked: preset == basic.whiteBalance) {
                                          if preset == .auto {
                                              guard let renderer else { return }
                                              Task { await library.autoWhiteBalance(with: renderer) }
                                          } else {
                                              library.changeEdit { $0.basic.choose(preset) }
                                          }
                                      }
                                  })
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("White Balance Preset")
                    EyedropperButton(isOn: library.isPickingWhiteBalance) { library.toggleWhiteBalancePicker() }
                        .disabled(renderer == nil)
                }
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
            }
            // White balance can't be shown until the camera's has been read from the photo.
            .disabled(library.selectedEdit?.asShot == nil)
            InspectorCard(title: "Basic", isOn: library.isOnBinding(.light),
                          canReset: basic.exposure != 0 || basic.contrast != 0 || basic.texture != 0
                              || basic.clarity != 0 || basic.dehaze != 0 || basic.highlights != 0 || basic.shadows != 0
                              || basic.whites != 0 || basic.blacks != 0,
                          reset: {
                              library.changeEdit {
                                  $0.basic.exposure = 0
                                  $0.basic.contrast = 0
                                  $0.basic.texture = 0
                                  $0.basic.clarity = 0
                                  $0.basic.dehaze = 0
                                  $0.basic.highlights = 0
                                  $0.basic.shadows = 0
                                  $0.basic.whites = 0
                                  $0.basic.blacks = 0
                              }
                          }) {
                // Grouped and ordered as in Lightroom's Basic panel, with Auto on the Tone row as there.
                HStack {
                    sectionHeading("Tone")
                    Spacer()
                    Button("Auto") {
                        guard let renderer else { return }
                        Task { await library.autoTone(with: renderer) }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .disabled(renderer == nil || library.isAutoAdjusting)
                    .help("Set Exposure, Contrast, Highlights, Shadows, Whites and Blacks from the photo")
                    .accessibilityLabel("Auto Tone")
                }
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
                sectionHeading("Presence")
                    .padding(.top, 6)
                AdjustmentSlider(
                    title: "Texture",
                    value: Binding(get: { basic.texture },
                                   set: { value in library.changeEdit { $0.basic.texture = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.textureTrack,
                    reset: { library.changeEdit { $0.basic.texture = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Clarity",
                    value: Binding(get: { basic.clarity },
                                   set: { value in library.changeEdit { $0.basic.clarity = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.clarityTrack,
                    reset: { library.changeEdit { $0.basic.clarity = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Dehaze",
                    value: Binding(get: { basic.dehaze },
                                   set: { value in library.changeEdit { $0.basic.dehaze = value } }),
                    range: -100...100, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
                    showsSign: true, track: Self.dehazeTrack,
                    reset: { library.changeEdit { $0.basic.dehaze = 0 } },
                    isAdjusting: { library.isAdjusting = $0 })
            }
            .disabled(library.selectedEdit == nil)
            InspectorCard(title: "Color", isOn: library.isOnBinding(.color),
                          canReset: basic.vibrance != 0 || basic.saturation != 0,
                          reset: {
                              library.changeEdit {
                                  $0.basic.vibrance = 0
                                  $0.basic.saturation = 0
                              }
                          }) {
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
            }
            .disabled(library.selectedEdit == nil)
            InspectorCard(title: "Curve", isOn: library.isOnBinding(.curve),
                          canReset: !(library.selectedEdit?.recipe.curve.isIdentity ?? true),
                          reset: { library.changeEdit { $0.curve = ToneCurve() } }) {
                CurveEditor(library: library)
            }
            .disabled(library.selectedEdit == nil)
            detailCard
            lensCard
            transformCard
            vignetteCard
            LookSection(library: library)
            if let unsaved = library.selectedEdit?.unsaved {
                InspectorCard {
                    Text(Self.message(for: unsaved))
                        .foregroundStyle(.secondary)
                    if unsaved == .noAccess {
                        Button("Grant Access…") { library.grantWriteAccessForSelectedPhoto() }
                    }
                }
            } else if let photo = library.browse.selectedPhoto, library.unsavedMetadata.contains(photo) {
                InspectorCard {
                    Text("Rating and flag not saved. Proof needs permission to save in this photo's folder.")
                        .foregroundStyle(.secondary)
                    Button("Grant Access…") { library.grantWriteAccessForSelectedPhoto() }
                }
            }
        }
    }

    private var basic: BasicAdjustments { library.selectedEdit?.recipe.basic ?? BasicAdjustments() }

    /// Sharpening and noise reduction, which `CIRAWFilter` applies as it decodes. The sliders
    /// start at the camera's values; Reset returns to them, and the switch off shows them.
    private var detailCard: some View {
        let detail = library.selectedEdit?.recipe.detail ?? DetailAdjustments()
        let shown = shownDetail
        return InspectorCard(title: "Detail", isOn: library.isOnBinding(.detail), canReset: !detail.isNeutral,
                             reset: { library.changeEdit { $0.detail = DetailAdjustments() } }) {
            // Grouped as in Lightroom's Detail panel, so Detail reads as part of noise reduction
            // rather than as the card's own control.
            sectionHeading("Sharpening")
            detailSlider("Amount", spoken: "Sharpening Amount", \.sharpening,
                         help: "Shows at 100% zoom, or when the photo is shown at more than half its size")
            sectionHeading("Noise Reduction")
                .padding(.top, 6)
            detailSlider("Luminance", spoken: "Luminance Noise Reduction", \.noiseReduction,
                         help: "Smooths brightness noise. The camera's amount follows the photo's ISO")
            detailSlider("Detail", spoken: "Noise Reduction Detail", \.noiseReductionDetail,
                         help: "How much fine detail luminance noise reduction keeps. No effect while Luminance is 0")
                // `CIRAWFilter` ignores it without luminance noise reduction to temper.
                .disabled((shown?.noiseReduction ?? 0) == 0)
            detailSlider("Color", spoken: "Color Noise Reduction", \.colorNoiseReduction,
                         help: "Smooths colored speckles")
        }
        // The sliders can't show the camera's values until they have been read from the photo.
        .disabled(shown == nil)
    }

    /// The lens the photo was taken with, its correction profile, which `CIRAWFilter` applies as
    /// it decodes, and Remove Chromatic Aberration, which Proof measures. Many RAW files carry no
    /// profile, such as Leica M files; the card then says so in place of the profile's switch.
    private var lensCard: some View {
        let edit = library.selectedEdit
        let lens = edit?.cameraLens
        let corrections = edit?.recipe.lens ?? LensCorrections()
        return InspectorCard(title: "Lens Corrections", isOn: library.isOnBinding(.lens), canReset: !corrections.isNeutral,
                             reset: { library.changeEdit { $0.lens = LensCorrections() } }) {
            if let lens {
                lensRow("Lens", value: lens.name ?? "Not recorded")
            }
            lensSwitch("Remove Chromatic Aberration", isOn: Binding(
                get: { corrections.chromaticAberration != nil || library.isMeasuringChromaticAberration },
                set: { value in
                    guard let renderer else { return }
                    Task { await library.setRemovesChromaticAberration(value, with: renderer) }
                }),
                isBusy: library.isMeasuringChromaticAberration,
                help: "Lines up the red and blue fringes along edges, measured from this photo")
                .disabled(renderer == nil || library.isAutoAdjusting)
            // A photo without a profile says so instead of showing a switch that can't turn on.
            if let lens, lens.hasProfile {
                lensSwitch("Profile Corrections", isOn: Binding(
                    get: { corrections.appliesProfile(for: lens) },
                    set: { value in
                        // Back to the decoder's default rather than a saved value when they match,
                        // so the edit stays neutral.
                        library.changeEdit { $0.lens.profile = value == lens.profileIsOnByDefault ? nil : value }
                    }),
                    help: "Corrects the lens's distortion and darkened corners with the profile in the photo")
            } else if let lens {
                lensRow("Profile", value: "None in this photo")
                    .help(lens.name == nil ? "The photo carries no lens correction data"
                                           : "The photo carries no correction data for this lens")
            }
            // Manual corrections, for lenses without a profile, grouped as in Lightroom's Manual tab.
            sectionHeading("Distortion")
                .padding(.top, 6)
            lensSlider("Amount", spoken: "Distortion Amount", range: LensCorrections.distortionRange,
                       value: corrections.distortion ?? 0,
                       set: { value, lens in lens.distortion = value == 0 ? nil : value },
                       showsGrid: true,
                       help: "Straightens lines that bow outward, or inward with negative values. The photo fills the frame")
            sectionHeading("Vignetting")
                .padding(.top, 6)
            let vignetting = corrections.vignetting ?? LensVignetting()
            lensSlider("Amount", spoken: "Lens Vignetting Amount", range: LensVignetting.amountRange,
                       value: vignetting.amount, track: Self.vignetteAmountTrack,
                       set: { value, lens in Self.setVignetting(&lens) { $0.amount = value } },
                       help: "Brightens the corners the lens darkened, or darkens them")
            // The midpoint does nothing without an amount, as in Lightroom.
            lensSlider("Midpoint", spoken: "Lens Vignetting Midpoint", range: LensVignetting.midpointRange,
                       value: vignetting.midpoint, showsSign: false, defaultValue: 50,
                       set: { value, lens in Self.setVignetting(&lens) { $0.midpoint = value } },
                       help: "How far toward the center the correction reaches")
                .disabled(vignetting.amount == 0)
        }
        .disabled(edit == nil)
    }

    /// Perspective correction, as in Lightroom's Transform panel: Upright sets the sliders from
    /// lines in the photo, or from guides drawn on it, and the sliders stay editable.
    private var transformCard: some View {
        let edit = library.selectedEdit
        let transform = edit?.recipe.transform ?? PerspectiveTransform()
        return InspectorCard(title: "Transform", isOn: library.isOnBinding(.transform), canReset: !transform.isNeutral || !transform.guides.isEmpty,
                             reset: {
                                 library.isDrawingGuides = false
                                 library.changeEdit { $0.transform = PerspectiveTransform() }
                             }) {
            sectionHeading("Upright")
            Picker("Upright", selection: Binding(
                get: { transform.upright },
                set: { mode in
                    guard let renderer else { return }
                    Task { await library.setUpright(mode, with: renderer) }
                })) {
                Text("Off").tag(UprightMode?.none)
                Text("Auto").tag(UprightMode?.some(.auto))
                Text("Guided").tag(UprightMode?.some(.guided))
                Text("Level").tag(UprightMode?.some(.level))
                Text("Vertical").tag(UprightMode?.some(.vertical))
                Text("Full").tag(UprightMode?.some(.full))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Six modes, as in Lightroom: mini keeps them within the inspector's width.
            .controlSize(.mini)
            .disabled(renderer == nil || library.isFindingLines)
            .help("Auto balances level and perspective. Guided follows lines you draw. Level turns the photo level, Vertical also makes upright lines parallel, Full also makes level lines parallel")
            uprightStatus(transform)
            lensSwitch("Constrain Crop", isOn: Binding(
                get: { transform.constrainCrop },
                set: { value in library.changeEdit { $0.transform.constrainCrop = value } }),
                help: "Enlarges the corrected photo so it fills the frame, with no empty edges")
            sectionHeading("Manual")
                .padding(.top, 6)
            transformSlider("Vertical", \.vertical, range: PerspectiveTransform.tiltRange,
                            help: "Tilts the photo top to bottom. Negative values straighten a building that leans back")
            transformSlider("Horizontal", \.horizontal, range: PerspectiveTransform.tiltRange,
                            help: "Tilts the photo side to side, to face a wall square on")
            transformSlider("Rotate", \.rotate, range: PerspectiveTransform.rotateRange, step: 0.1, fractionDigits: 1,
                            unit: "degrees", help: "Turns the photo, in degrees clockwise")
            transformSlider("Aspect", \.aspect, range: PerspectiveTransform.aspectRange,
                            help: "Stretches the photo across, or upward with negative values, to undo the stretch a correction leaves")
            transformSlider("Scale", \.scale, range: PerspectiveTransform.scaleRange, defaultValue: 100, showsSign: false,
                            unit: "percent", help: "Enlarges or shrinks the photo about its center")
            transformSlider("X Offset", \.xOffset, range: PerspectiveTransform.offsetRange,
                            help: "Moves the photo right, or left with negative values")
            transformSlider("Y Offset", \.yOffset, range: PerspectiveTransform.offsetRange,
                            help: "Moves the photo up, or down with negative values")
        }
        .disabled(edit == nil)
    }

    /// What Upright is doing below its buttons: looking for lines, finding none, or Guided's
    /// instructions and buttons.
    @ViewBuilder
    private func uprightStatus(_ transform: PerspectiveTransform) -> some View {
        if library.isFindingLines {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Finding lines…")
                    .foregroundStyle(.secondary)
            }
        } else if library.foundNoLines {
            Text("No straight lines found in this photo.")
                .foregroundStyle(.secondary)
        } else if transform.upright == .guided {
            if library.isDrawingGuides {
                // Short enough for one line: a longer text widens the inspector, which keeps the width.
                Text("Drag along 2 to 4 straight edges.")
                    .foregroundStyle(.secondary)
                    .help("Draw along edges that should be upright or level. Two each way set every slider")
            }
            HStack {
                Button("Clear Guides") { library.clearGuides() }
                    .disabled(transform.guides.isEmpty)
                Spacer()
                if library.isDrawingGuides {
                    Button("Done") { library.isDrawingGuides = false }
                        .keyboardShortcut(.cancelAction)
                } else {
                    Button("Edit Guides") { library.isDrawingGuides = true }
                }
            }
            .controlSize(.small)
        }
    }

    private func transformSlider(_ title: String, _ keyPath: WritableKeyPath<PerspectiveTransform, Double>,
                                 range: ClosedRange<Double>, step: Double = 1, fractionDigits: Int = 0,
                                 defaultValue: Double = 0, showsSign: Bool = true, unit: String = "",
                                 help: String) -> some View {
        let transform = library.selectedEdit?.recipe.transform ?? PerspectiveTransform()
        return AdjustmentSlider(
            title: title,
            spokenTitle: "Transform \(title)",
            value: Binding(get: { transform[keyPath: keyPath] },
                           set: { new in library.changeEdit { $0.transform[keyPath: keyPath] = new } }),
            range: range, fineStep: step, step: step, coarseStep: step * 10, fractionDigits: fractionDigits,
            showsSign: showsSign, unit: unit,
            reset: { library.changeEdit { $0.transform[keyPath: keyPath] = defaultValue } },
            isAdjusting: { adjusting in
                library.isAdjusting = adjusting
                library.isAdjustingGeometry = adjusting
            })
            .help(help)
    }

    /// Changes the lens vignetting, back to `nil` at its defaults so the edit stays neutral.
    private static func setVignetting(_ lens: inout LensCorrections, _ change: (inout LensVignetting) -> Void) {
        var vignetting = lens.vignetting ?? LensVignetting()
        change(&vignetting)
        lens.vignetting = vignetting == LensVignetting() ? nil : vignetting
    }

    private func lensSlider(_ title: String, spoken: String, range: ClosedRange<Double>, value: Double,
                            showsSign: Bool = true, track: [Color] = [], defaultValue: Double = 0,
                            set: @escaping (Double, inout LensCorrections) -> Void, showsGrid: Bool = false,
                            help: String) -> some View {
        AdjustmentSlider(
            title: title,
            spokenTitle: spoken,
            value: Binding(get: { value }, set: { new in library.changeEdit { set(new, &$0.lens) } }),
            range: range, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
            showsSign: showsSign, track: track,
            reset: { library.changeEdit { set(defaultValue, &$0.lens) } },
            isAdjusting: { adjusting in
                library.isAdjusting = adjusting
                if showsGrid { library.isAdjustingGeometry = adjusting }
            })
            .help(help)
    }

    /// A switch on the card's trailing edge, lined up with the cards' own, with its name ahead of
    /// it, and a spinner beside it while `isBusy`.
    private func lensSwitch(_ title: String, isOn: Binding<Bool>, isBusy: Bool = false, help: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(InspectorCard<EmptyView>.labelColor)
                .accessibilityHidden(true)
            Spacer()
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Measuring")
            }
            Toggle(title, isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                // Green, as the cards' own switches are.
                .tint(.green)
                .labelsHidden()
        }
        .help(help)
    }

    /// A name and its value, the value on the card's trailing edge like the switches.
    private func lensRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(InspectorCard<EmptyView>.labelColor)
                .fixedSize()
            Spacer(minLength: 12)
            // Wraps rather than truncates: a lens name is often longer than the space beside its label.
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    /// Lightroom's post-crop vignette: it centers on the cropped frame and follows any crop.
    private var vignetteCard: some View {
        let vignette = library.selectedEdit?.recipe.vignette ?? VignetteAdjustments()
        return InspectorCard(title: "Vignette", isOn: library.isOnBinding(.vignette), canReset: !vignette.isNeutral,
                             reset: { library.changeEdit { $0.vignette = VignetteAdjustments() } }) {
            vignetteSlider("Amount", spoken: "Vignette Amount", \.amount, range: VignetteAdjustments.amountRange,
                           showsSign: true, track: Self.vignetteAmountTrack,
                           help: "Darkens the edges of the photo, or lightens them")
            // The shape does nothing without an amount, as in Lightroom.
            Group {
                vignetteSlider("Midpoint", spoken: "Vignette Midpoint", \.midpoint, range: VignetteAdjustments.midpointRange,
                               help: "How far toward the center the vignette reaches")
                vignetteSlider("Roundness", spoken: "Vignette Roundness", \.roundness, range: VignetteAdjustments.roundnessRange,
                               showsSign: true, help: "From the frame's rectangle to a circle")
                vignetteSlider("Feather", spoken: "Vignette Feather", \.feather, range: VignetteAdjustments.featherRange,
                               help: "How gradually the vignette fades in. At 0 it has a hard edge")
            }
            .disabled(vignette.amount == 0)
        }
        .disabled(library.selectedEdit == nil)
    }

    private func vignetteSlider(_ title: String, spoken: String, _ keyPath: WritableKeyPath<VignetteAdjustments, Double>,
                                range: ClosedRange<Double>, showsSign: Bool = false, track: [Color] = [],
                                help: String) -> some View {
        AdjustmentSlider(
            title: title,
            spokenTitle: spoken,
            value: Binding(get: { library.selectedEdit?.recipe.vignette[keyPath: keyPath] ?? VignetteAdjustments()[keyPath: keyPath] },
                           set: { value in library.changeEdit { $0.vignette[keyPath: keyPath] = value } }),
            range: range, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
            showsSign: showsSign, track: track,
            reset: { library.changeEdit { $0.vignette[keyPath: keyPath] = VignetteAdjustments()[keyPath: keyPath] } },
            isAdjusting: { library.isAdjusting = $0 })
            .help(help)
    }

    /// A heading over a group of sliders inside a card, as in Lightroom's panels.
    private func sectionHeading(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }

    /// The detail amounts the photo shows, the camera's where the edit has none; `nil` until the
    /// camera's have been read.
    private var shownDetail: DetailAdjustments? {
        guard let edit = library.selectedEdit else { return nil }
        return edit.cameraDetail.map { edit.recipe.detail.shown(camera: $0) }
    }

    private func detailSlider(_ title: String, spoken: String, _ keyPath: WritableKeyPath<DetailAdjustments, Double?>,
                              help: String) -> some View {
        AdjustmentSlider(
            title: title,
            spokenTitle: spoken,
            // Read from the edit on each call, not from a copy taken when the card was drawn: the
            // slider reads the value back right after setting it, to show the number.
            value: Binding(get: { shownDetail?[keyPath: keyPath] ?? 0 },
                           set: { value in library.changeEdit { $0.detail[keyPath: keyPath] = value } }),
            range: DetailAdjustments.range, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
            reset: { library.changeEdit { $0.detail[keyPath: keyPath] = nil } },
            isAdjusting: { library.isAdjusting = $0 })
            .help(help)
    }

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
    /// Dark to light, the way exposure moves the photo. A soft range of grays rather than black to
    /// white, as Lightroom draws it, so the tracks don't compete with the photo.
    private static let exposureTrack = [Color(white: 0.12), Color(white: 0.62)]
    /// The other tone sliders run dark to light end to end too, as Lightroom draws them.
    private static let contrastTrack = exposureTrack
    /// Texture, Clarity and Dehaze run light to dark, the reverse of the tone sliders, as Lightroom draws them.
    private static let textureTrack = Array(exposureTrack.reversed())
    private static let clarityTrack = textureTrack
    private static let dehazeTrack = textureTrack
    /// Dark to light, the way the edges move, as Lightroom draws Vignette's Amount.
    private static let vignetteAmountTrack = exposureTrack
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
        case .auto: "Auto"
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
