import AppKit
import SwiftUI
import ProofKit
import ProofUI

@main
struct ProofApp: App {
    @State private var library = Library(platform: .mac)

    init() {
        // Always dark, whatever the system appearance (#42), so the photo is judged against a calm
        // surround. Set on the app rather than the window so menus, sheets and panels follow.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
    }

    var body: some Scene {
        // One window, like other photo editors: the sidebar selection and filter belong to it.
        Window("Proof", id: "main") {
            ContentView(library: library)
                .macInspectorControls()
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
            // ⌘C and ⌘V copy and paste the photos' settings, as in Lightroom, and ⌘A selects every
            // photo shown, except while a field is being typed in. Their titles can't follow the
            // focus, so the Settings items below name what they do.
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") { Self.sendToTextField(#selector(NSText.cut(_:))) }
                    .keyboardShortcut("x")
                Button("Copy") {
                    if library.canCopySettings && !Self.isTyping {
                        library.chooseSettingsToCopy()
                    } else {
                        Self.sendToTextField(#selector(NSText.copy(_:)))
                    }
                }
                .keyboardShortcut("c")
                Button("Paste") {
                    if library.canPasteSettings && !Self.isTyping {
                        library.pasteSettings()
                    } else {
                        Self.sendToTextField(#selector(NSText.paste(_:)))
                    }
                }
                .keyboardShortcut("v")
                Button("Select All") {
                    if library.canSelectPhotos && !Self.isTyping {
                        library.browse.selectAll(library.shownPhotos)
                    } else {
                        Self.sendToTextField(#selector(NSText.selectAll(_:)))
                    }
                }
                .keyboardShortcut("a")
                // In Edit, the photo shown stays selected.
                Button("Deselect All") { library.deselectAll() }
                    .keyboardShortcut("a", modifiers: [.command, .option])
                    .disabled(library.browse.selectedPhoto == nil || library.isEditing && !library.browse.hasMultipleSelection)
                Divider()
                Button("Copy Settings…") { library.chooseSettingsToCopy() }
                    .disabled(!library.canCopySettings)
                Button("Paste Settings") { library.pasteSettings() }
                    .disabled(!library.canPasteSettings)
            }
            CommandGroup(after: .newItem) {
                Button("Add Folder…") { library.requestFolder(.add) }
                    .keyboardShortcut("o")
                Divider()
                // The selected photos, or the selected folder when no photo is selected.
                Button("Show in Finder") { library.showInFinder(library.selectedFileURLs) }
                    .disabled(!library.hasSelectedFiles)
                Button("Copy Path") { library.copyPaths(library.selectedFileURLs) }
                    .keyboardShortcut("c", modifiers: [.command, .option])
                    .disabled(!library.hasSelectedFiles)
                Divider()
                Button("Export…") { library.requestExport() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!library.canExport)
                ExportToMenu(library: library, isDisabled: !library.canExport)
            }
            CommandGroup(before: .sidebar) {
                Menu("Filter") { FilterMenu(library: library) }
                    .disabled(library.selection == nil)
                Divider()
                Button("Reload Folders") { library.refresh() }
                    .keyboardShortcut("r")
                    .disabled(library.locations.isEmpty || library.isEditing)
                Divider()
            }
            CommandGroup(after: .sidebar) {
                Button(library.isShowingInfo ? "Hide Info" : "Show Info") { library.toggleInfo() }
                    .keyboardShortcut("i")
                    .disabled(library.selection == nil)
                Button(library.isInspectorShown ? "Hide Inspector" : "Show Inspector") {
                    library.isInspectorShown.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .control])
                .disabled(!library.isEditing)
                Button(library.isFilmstripShown ? "Hide Filmstrip" : "Show Filmstrip") {
                    library.isFilmstripShown.toggle()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])
                .disabled(!library.isEditing)
                Button(library.isHistoryShown ? "Hide History" : "Show History") {
                    library.isHistoryShown.toggle()
                }
                .keyboardShortcut("y")
                .disabled(!library.isEditing)
                CanvasColorMenu(library: library)
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
                    .disabled(library.isEditing || library.browse.selectedPhoto?.isEditable != true)
                // ⌘↑, as Finder's Enclosing Folder. Esc only closes tools, such as the crop tool, so it
                // never leaves Edit by surprise.
                Button("Back to Folder") { library.browse.finishEditing() }
                    .keyboardShortcut(.upArrow)
                    .disabled(!library.isEditing)
                // Like every action in the menu bar and the right-click menu, it acts on all selected photos.
                let toRevert = library.photosToRevert()
                Button(toRevert.count > 1 ? "Revert \(toRevert.count) Photos to Original…" : "Revert to Original") {
                    library.requestRevert()
                }
                .disabled(toRevert.isEmpty)
                // Backslash, as in Lightroom. A toggle, so the menu marks it while the original shows.
                Toggle("Show Original", isOn: Binding(get: { library.browse.isShowingOriginal },
                                                      set: { _ in library.toggleOriginal() }))
                    .keyboardShortcut("\\", modifiers: [])
                    .disabled(!library.isEditing || library.isCropping || library.isPickingWhiteBalance
                              || library.selectedEdit == nil)
                Divider()
                // C opens and closes the crop tool, as R does in Lightroom's.
                // While the ruler is on, Return and Esc end it instead, from its pill on the photo.
                if library.isCropping {
                    Button("Done Cropping") { library.finishCropping() }
                        .keyboardShortcut(library.isDrawingLevelLine ? nil : KeyboardShortcut(.return, modifiers: []))
                    Button("Cancel Cropping") { library.cancelCropping() }
                        .keyboardShortcut(library.isDrawingLevelLine ? nil : KeyboardShortcut(.escape, modifiers: []))
                    Button("Swap Crop Orientation") { library.swapCropOrientation() }
                        .keyboardShortcut("x", modifiers: [])
                } else {
                    Button("Crop") { library.startCropping() }
                        .keyboardShortcut("c", modifiers: [])
                        .disabled(!library.isEditing || library.selectedEdit == nil)
                }
                // Q, as in Lightroom. A toggle, so the menu marks it while the tool is open.
                Toggle("Spot Removal", isOn: Binding(get: { library.isRemovingSpots },
                                                     set: { _ in library.toggleSpotRemoval() }))
                    .keyboardShortcut("q", modifiers: [])
                    .disabled(!library.isEditing || library.isCropping || library.selectedEdit == nil)
                Toggle("Masks", isOn: Binding(get: { library.isMasking }, set: { _ in library.toggleMasks() }))
                    .keyboardShortcut("m", modifiers: [])
                    .disabled(!library.isEditing || library.isCropping || library.selectedEdit == nil)
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
                // The same choice as the Profile row in the inspector. A photo with one profile shows
                // it checked and can't change it.
                let profiles = library.isEditing ? library.selectedEdit?.profiles : nil
                Picker("Profile", selection: Binding(
                    get: { profiles?.resolved(library.selectedEdit?.recipe.profile ?? .embedded) ?? .embedded },
                    set: { profile in library.changeEdit { $0.profile = profile } })) {
                    if let profiles {
                        ForEach(profiles.offersChoice ? CameraProfile.allCases : [profiles.resolved(.embedded)],
                                id: \.self) { Text(profiles.label(for: $0)).tag($0) }
                    }
                }
                .pickerStyle(.menu)
                .disabled(profiles?.offersChoice != true)
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
                // Checked when every selected photo shares the rating or flag.
                Picker("Rating", selection: Binding(get: { library.commonRating(of: library.selectedPhotosInOrder) ?? -1 },
                                                    set: { library.setRating($0) })) {
                    ForEach(0...5, id: \.self) { rating in
                        Text(RatingBadges.title(ofRating: rating)).tag(rating)
                            .keyboardShortcut(KeyEquivalent(Character("\(rating)")), modifiers: [])
                    }
                }
                .pickerStyle(.inline)
                .disabled(library.browse.selectedPhoto == nil)
                Divider()
                Picker("Flag", selection: Binding(get: { library.commonFlag(of: library.selectedPhotosInOrder) },
                                                  set: { if let flag = $0 { library.setFlag(flag) } })) {
                    Text("Flagged").tag(PhotoMetadata.Flag?.some(.flagged)).keyboardShortcut("p", modifiers: [])
                    Text("Unflagged").tag(PhotoMetadata.Flag?.some(.unflagged)).keyboardShortcut("u", modifiers: [])
                    // While cropping, X swaps the crop's orientation instead, as in Lightroom.
                    Text("Rejected").tag(PhotoMetadata.Flag?.some(.rejected))
                        .keyboardShortcut(library.isCropping ? nil : KeyboardShortcut("x", modifiers: []))
                }
                .pickerStyle(.inline)
                .disabled(library.browse.selectedPhoto == nil)
            }
        }
    }

    /// A text field is being typed in, so the pasteboard commands act on its text.
    private static var isTyping: Bool {
        NSApp.keyWindow?.firstResponder is NSText
    }

    private static func sendToTextField(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
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
            Group {
                // In Edit the leading column holds the History panel instead of the folders.
                if library.isEditing {
                    HistorySidebar(library: library)
                } else {
                    FolderSidebar(library: library)
                }
            }
                .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 360)
                .toolbar(removing: library.isEditing ? .sidebarToggle : nil)
        } detail: {
            Group {
                if library.isEditing {
                    editor
                } else {
                    PhotoBrowser(library: library)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // Declared on the grid's column, as Edit's are on the photo's, so the
                        // toolbar keeps its groups apart.
                        .toolbar { browseToolbar }
                        .background(Color.interfaceBackground.ignoresSafeArea())
                }
            }
            .inspector(isPresented: Binding(get: { library.isEditing ? library.isInspectorShown : library.isInfoShown },
                                            set: { if library.isEditing { library.isInspectorShown = $0 } else { library.isInfoShown = $0 } })) {
                Group {
                    if !library.isEditing {
                        InfoInspector(library: library)
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                                // Only once fully open; while sliding it may be narrower.
                                if width >= 300 { library.infoPanelWidth = width }
                            }
                    } else if library.browse.selectedPhoto?.isEditable == false {
                        notEditable
                    } else if library.isCropping {
                        CropInspector(library: library, renderer: renderer)
                    } else if library.isRemovingSpots {
                        SpotRemovalInspector(library: library)
                    } else if library.isMasking {
                        MasksInspector(library: library, renderer: renderer)
                    } else {
                        AdjustmentsInspector(library: library, renderer: renderer, tools: .all) {
                            LookSection(library: library)
                        }
                    }
                }
                // Wide enough at its narrowest for the longest card header, "Lens Corrections" beside Reset and its switch.
                .inspectorColumnWidth(min: 300, ideal: 320, max: 420)
            }
        }
        // Both modes follow the system appearance. The toolbar keeps the system's default
        // background and scroll edge effect, which keep the title readable over scrolled content.
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(library.windowTitle)
        .navigationSubtitle(library.windowSubtitle)
        .toolbar {
            if library.isEditing {
                editToolbar
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
        .sheet(isPresented: $library.isChoosingSettingsToCopy) {
            CopySettingsSheet(library: library)
        }
        // Export turns the sheet into the export's progress, which stays until Done (#196).
        .sheet(isPresented: Binding(get: { !library.photosToExport.isEmpty || library.exports.isVisible },
                                    set: { if !$0 { library.photosToExport = [] } })) {
            if library.photosToExport.isEmpty {
                ExportProgressView(exports: library.exports)
            } else {
                ExportSheet(library: library, photos: library.photosToExport)
            }
        }
        // A single photo reverts without asking, as Undo brings it back right there. Several may
        // include photos out of sight, each with its own undo history.
        .confirmationDialog("Revert \(library.photosPendingRevert.count) photos to their originals?",
                            isPresented: $library.isConfirmingRevert) {
            Button("Revert \(library.photosPendingRevert.count) Photos", role: .destructive) { library.revertPendingPhotos() }
        } message: {
            Text("Their edits are removed. To bring one back, open it in Edit and choose Undo before quitting Proof.")
        }
        .alert("Something Went Wrong", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("OK") { library.errorMessage = nil }
        } message: {
            Text(library.errorMessage ?? "")
        }
        .onAppear {
            TextFieldKeys.watch { [library] in
                library.isCropping || library.isMasking || library.isRemovingSpots
                    || library.isDrawingGuides || library.isPickingWhiteBalance
            }
        }
        .onChange(of: library.isEditing) { _, isEditing in
            if isEditing {
                browseColumnVisibility = columnVisibility
                columnVisibility = library.isHistoryShown ? .all : .detailOnly
            } else {
                columnVisibility = browseColumnVisibility
            }
        }
        .onChange(of: library.isHistoryShown) { _, isShown in
            if library.isEditing { columnVisibility = isShown ? .all : .detailOnly }
        }
        // Dragging the History panel closed hides it as its button does.
        .onChange(of: columnVisibility) { _, visibility in
            if library.isEditing { library.isHistoryShown = visibility != .detailOnly }
        }
    }

    @ToolbarContentBuilder private var browseToolbar: some ToolbarContent {
        // On a filter row it narrows the row's photos further.
        if library.selection != nil {
            ToolbarItem { FilterButton(library: library) }
        }
        // Only while the Info panel is open; View › Show Info, ⌘I and a photo's right-click menu
        // open it. The same symbol as the inspector button in Edit, which also hides a side panel.
        if library.isInfoShown {
            ToolbarSpacer(.fixed)
            ToolbarItem {
                Button("Hide Info", systemImage: "sidebar.trailing") { library.isInfoShown = false }
                    .help("Hide the photo's info (⌘I)")
            }
        }
    }

    @ToolbarContentBuilder private var editToolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("Back to Folder", systemImage: "chevron.backward") { library.browse.finishEditing() }
                .help("Return to the folder (⌘↑)")
        }
        // The filmstrip's controls, beside the back button, away from the tools that change the
        // photo. They share the back button's capsule: a ToolbarSpacer between them is ignored
        // here, and a Divider draws as a short horizontal dash.
        ToolbarItemGroup(placement: .navigation) {
            if library.selection != nil {
                FilterButton(library: library)
            }
            Button(library.isFilmstripShown ? "Hide Filmstrip" : "Show Filmstrip",
                   systemImage: "rectangle.bottomthird.inset.filled") {
                library.isFilmstripShown.toggle()
            }
            .help(library.isFilmstripShown ? "Hide the filmstrip (⌥⌘F)" : "Show the filmstrip (⌥⌘F)")
            // Beside the filmstrip's button: both show or hide a panel, and History opens on this side.
            Button(library.isHistoryShown ? "Hide History" : "Show History",
                   systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                library.isHistoryShown.toggle()
            }
            .help(library.isHistoryShown ? "Hide the photo's history (⌘Y)" : "Show the photo's history (⌘Y)")
        }
    }


    /// The filmstrip in its card, with the inspector cards' gray. The filter and the button that
    /// hides it are in the toolbar, so the card holds only thumbnails.
    private var filmstripCard: some View {
        Group {
            if isFilmstripEmpty {
                filmstripEmptyState
            } else {
                Filmstrip(library: library, photos: library.shownPhotos)
            }
        }
        .background(RoundedRectangle(cornerRadius: InspectorCard<EmptyView>.cornerRadius, style: .continuous)
            .fill(Color(white: InspectorCard<EmptyView>.fillGray(for: colorScheme))))
        .clipShape(.rect(cornerRadius: InspectorCard<EmptyView>.cornerRadius, style: .continuous))
    }

    /// True when no photo passes the filter. The photo shown stays in `visiblePhotos` so the canvas
    /// keeps it, but the filmstrip leaves it out rather than show it under a filter it fails.
    private var isFilmstripEmpty: Bool {
        let filter = library.activeFilter
        return !filter.isEmpty && !library.visiblePhotos.contains { filter.includes($0.photo) }
    }

    /// Centered in the card, at the filmstrip's height so the photo doesn't move. Clear Filter
    /// clears the toolbar's filter; a sidebar filter row is changed in the sidebar.
    private var filmstripEmptyState: some View {
        VStack(spacing: 8) {
            Text("No photos match the filter.")
                .foregroundStyle(.secondary)
            if !library.filter.isEmpty {
                Button("Clear Filter") { library.filter = .none }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Filmstrip.height)
    }

    /// In place of the photo and the inspector's controls for a JPEG or HEIC, reached from the
    /// filmstrip in Edit. Edit doesn't open them until #239.
    private var notEditable: some View {
        ContentUnavailableView("Can't Edit This Photo Yet", systemImage: "photo",
                               description: Text("Proof edits RAW photos. JPEG and HEIC photos can be rated and flagged in Browse."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var editor: some View {
        Group {
            if let renderer, let url = library.selectedPhotoURL {
                VStack(spacing: 0) {
                    // The same margin while cropping, so the photo doesn't shrink when the tool opens: the
                    // handles are drawn inside the crop border, and their 12 pt reach fits in the
                    // 16 pt below the photo too.
                    Group {
                        if library.browse.selectedPhoto?.isEditable == false {
                            notEditable
                        } else if library.isSelectedPhotoInCloud {
                            CloudPhotoPreview(url: url, backdrop: library.canvasColor.color)
                        } else {
                            EditCanvas(library: library, url: url, renderer: renderer)
                        }
                    }
                    .padding([.top, .horizontal], 24)
                    .padding(.bottom, 16)
                    if library.isFilmstripShown {
                        filmstripCard
                            .padding([.horizontal, .bottom], 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    } else {
                        // With the canvas's 16 pt, the photo keeps a 24 pt margin below it.
                        Spacer().frame(height: 8)
                    }
                }
                .animation(.snappy(duration: 0.25), value: library.isFilmstripShown)
            } else {
                ContentUnavailableView("Metal Isn't Available", systemImage: "exclamationmark.triangle",
                                       description: Text("Proof needs a Mac with a Metal GPU to show photos."))
            }
        }
        // The canvas runs under the toolbar glass and stops at the inspector; the photo stays inside the safe area.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Never under the inspector on the trailing edge: its material would show the gray through.
        .background(library.canvasColor.color
            .ignoresSafeArea(edges: [.top, .leading, .bottom]))
        // Declared on the photo's column rather than the window, so the button sits over the
        // photo and stays put when the inspector opens and closes.
        .toolbar {
            // Stars and flags are separate groups, as in Lightroom, at the trailing end so the
            // title stands on its own.
            // They rate the photo shown only. The menu bar, its keys and the right-click menu act on
            // every selected photo.
            ToolbarItem {
                StarButtons(rating: library.selectedPhotoMetadata?.rating ?? 0) { rating in
                    library.setRating(rating, of: library.browse.selectedPhoto.map { [$0] } ?? [])
                }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem {
                FlagButtons(flag: library.selectedPhotoMetadata?.flag ?? .unflagged) { flag in
                    library.setFlag(flag, of: library.browse.selectedPhoto.map { [$0] } ?? [])
                }
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
                        .keyboardShortcut(library.isDrawingLevelLine ? nil : .cancelAction)
                        .help("Return to the crop from before the tool opened (Esc)")
                    Button("Done") { library.finishCropping() }
                        .keyboardShortcut(library.isDrawingLevelLine ? nil : KeyboardShortcut(.return, modifiers: []))
                        .help("Keep the crop (Return)")
                }
            } else {
                ToolbarItemGroup {
                    Button("Crop", systemImage: "crop") { library.startCropping() }
                        .help("Crop, straighten, rotate and flip the photo (C)")
                        .disabled(library.selectedEdit == nil)
                    Toggle(isOn: Binding(get: { library.isRemovingSpots }, set: { _ in library.toggleSpotRemoval() })) {
                        Label("Spot Removal", systemImage: "bandage")
                    }
                    .help("Remove dust and small spots (Q)")
                    .disabled(library.selectedEdit == nil)
                    Toggle(isOn: Binding(get: { library.isMasking }, set: { _ in library.toggleMasks() })) {
                        Label("Masks", systemImage: "circle.lefthalf.filled")
                    }
                    .help("Adjust part of the photo with gradients, a brush or its subject (M)")
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
}

/// The photo being edited, rendered with its current edit. A view of its own so it reads the
/// edit in its own body, and redraws on every change to it, including during a drag.
struct EditCanvas: View {
    let library: Library
    let url: URL
    let renderer: RAWRenderer
    /// The photo has neither its render nor a cached thumbnail to show yet.
    @State private var isWaiting = false

    var body: some View {
        PhotoCanvas(url: url, renderer: renderer, recipe: shownRecipe, backdrop: library.canvasColor,
                    angle: library.isCropping ? library.selectedCrop.angle : 0,
                    viewport: library.zoom.viewport, zoom: library.zoom, previews: ThumbnailCache.shared) { error in
            library.errorMessage = "The photo couldn't be shown. (\(error))"
        } onHistogram: { histogram, url in
            library.showHistogram(histogram, of: url)
        } onWaiting: { isWaiting = $0 }
        // A temporary indicator, so it may sit where the photo will appear.
        .overlay {
            if isWaiting {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Loading photo")
            }
        }
        .overlay {
            if library.isCropping, let frame = library.selectedCropFrame {
                CropOverlay(library: library, frame: frame, aspect: library.selectedCrop.aspect,
                           backdrop: library.canvasColor.color)
            } else if library.isRemovingSpots, let size = library.selectedEdit?.size {
                SpotOverlay(library: library, renderer: renderer, zoom: library.zoom, crop: shownRecipe.crop, photoSize: size)
            } else if library.isMasking, let size = library.selectedEdit?.size {
                MaskOverlay(library: library, zoom: library.zoom, crop: shownRecipe.crop, photoSize: size)
            } else if library.isPickingWhiteBalance {
                WhiteBalancePicker(library: library, renderer: renderer)
            } else if library.isDrawingGuides, let size = library.selectedEdit?.size {
                GuideOverlay(library: library, zoom: library.zoom, transform: shownRecipe.transform, crop: shownRecipe.crop,
                             photoSize: size)
            } else if library.isAdjustingGeometry {
                DistortionGrid(zoom: library.zoom)
            }
        }
        // A temporary tool, so it may sit on the photo: only while zoomed, in the corner under the
        // toolbar's zoom pop-up.
        .overlay(alignment: .topTrailing) {
            if let preview = library.zoom.preview, library.zoom.isEnabled, library.zoom.canPan {
                Navigator(zoom: library.zoom, preview: preview)
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
        // The crop tool shows the whole photo, so zoom is off while it's open.
        .onChange(of: library.isCropping, initial: true) { _, isCropping in
            library.zoom.isEnabled = !isCropping
            if isCropping { library.zoom.reset() }
        }
    }

    /// While cropping, the whole photo, turned and flipped: the canvas tilts it and the overlay
    /// marks the rectangle, so a drag doesn't wait for a render.
    private var shownRecipe: EditRecipe {
        var recipe = library.selectedEdit?.recipe ?? EditRecipe()
        if library.browse.isShowingOriginal { return recipe.original }
        if library.isCropping { recipe.crop = recipe.crop?.turnedOnly }
        recipe.maskOverlay = library.overlaidLayer
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
