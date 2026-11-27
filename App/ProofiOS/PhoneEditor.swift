import ProofKit
import ProofUI
import SwiftUI

/// Edit on iPhone (decision 0054): the photo with five tools in the bottom toolbar. Looks, Light,
/// Color and Finish each open a sheet of a few sliders with a compact and a medium height, and the
/// photo resizes to stay whole above it. Crop turns the canvas into a crop mode (`PhoneCropToolbar`).
/// Undo, History, Copy and Paste, Compare, the histogram and Reset are in the More menu. It is
/// pushed from the Edit button of the photo selected in the grid (#292), and Back returns there.
/// iPad keeps `PhotoView`.
struct PhoneEditor: View {
    @Bindable var library: Library
    let renderer: RAWRenderer?
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The tool whose sheet is open.
    @State private var tool: PhoneTool?
    @State private var sheetHeight = PresentationDetent.toolCompact
    /// The top of the sheet, in global coordinates, while one is up.
    @State private var sheetTop: CGFloat?
    /// The bottom of the space the photo is laid out in, in global coordinates.
    @State private var photoAreaBottom: CGFloat = 0
    @State private var isHistogramShown = false

    var body: some View {
        VStack(spacing: 0) {
            EditPhoto(library: library, renderer: renderer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(library.canvasColor.color)
                // A small floating panel, shown only while it is turned on in More, so it may sit
                // over the corner of the canvas as a temporary tool does.
                .overlay(alignment: .topLeading) {
                    if isHistogramShown && !library.isCropping {
                        HistogramView(histogram: library.selectedHistogram, height: 48)
                            .equatable()
                            .frame(width: 120)
                            .padding(10)
                            .background(Color.toolPanel, in: .rect(cornerRadius: 14))
                            // 12 points inside the photo's 16-point margin, so it stays clear of the
                            // photo's edge while zoomed.
                            .padding(28)
                            .transition(.opacity)
                    }
                }
            // No filmstrip (#286), so the photo has the room.
            if library.isCropping {
                PhoneStraightenSlider(library: library)
            }
        }
        // The photo fits above the sheet, so it never covers it.
        .padding(.bottom, sheetInset)
        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: { photoAreaBottom = $0 }
        .animation(.snappy(duration: 0.25), value: isHistogramShown)
        .background(Color.interfaceBackground.ignoresSafeArea())
        .navigationTitle(library.isCropping ? "Crop" : library.isSamplingWhiteBalance ? "White Balance" : library.windowTitle)
        .navigationSubtitle(library.browse.isShowingOriginal && !isInCanvasMode ? "Original" : "")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isInTool || isInCanvasMode)
        .sheet(isPresented: isSheetUp) {
            sheet
                // Opaque rather than glass. The tool sheets are a step lighter than the canvas; the
                // touch tools' panels keep the iPad inspector's colors, cards on the canvas gray.
                .presentationBackground(isInTool ? Color.interfaceBackground : Color.toolPanel)
                .presentationDetents(sheetHeights, selection: $sheetHeight)
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.scrolls)
                // The touch tools' controls are only here, so their sheet stays up until Done.
                .interactiveDismissDisabled(isInTool)
                .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { sheetTop = $0 }
                .onDisappear { sheetTop = nil }
                // Presented from the sheet, which is the top presentation while it is up.
                .sheet(isPresented: history(whileSheetIsUp: true)) { historySheet }
                .sheet(isPresented: copySettings(whileSheetIsUp: true)) { CopySettingsSheet(library: library) }
                .sheet(isPresented: export(whileSheetIsUp: true)) { ExportSheet(library: library) }
        }
        .sheet(isPresented: history(whileSheetIsUp: false)) { historySheet }
        .sheet(isPresented: copySettings(whileSheetIsUp: false)) { CopySettingsSheet(library: library) }
        .sheet(isPresented: export(whileSheetIsUp: false)) { ExportSheet(library: library) }
        // A phone in landscape has room for the photo only above a compact sheet.
        .onChange(of: verticalSizeClass, initial: true) {
            if verticalSizeClass == .compact { sheetHeight = .toolCompact }
        }
        .onChange(of: library.isCropping) { if library.isCropping { tool = nil } }
        .toolbar { toolbar }
    }

    // MARK: Sheets

    @ViewBuilder private var sheet: some View {
        if isInTool {
            // Spot removal and masks keep the controls they had in the iPhone inspector sheet (#228).
            if library.isRemovingSpots {
                SpotRemovalInspector(library: library)
            } else {
                MasksInspector(library: library, renderer: renderer)
            }
        } else if let tool {
            ToolSheet(library: library, renderer: renderer, tool: tool, close: { self.tool = nil }) {
                // The sheet lowers while the eyedropper is on the photo, and comes back after.
                self.tool = nil
                library.startSamplingWhiteBalance()
            }
            // Each tool starts at its first segment.
            .id(tool)
        }
    }

    /// A touch tool whose controls are in a sheet. Crop has its controls around the photo instead.
    private var isInTool: Bool { library.isRemovingSpots || library.isMasking }

    /// Crop and the white balance eyedropper are modes of the canvas, with their own bars.
    private var isInCanvasMode: Bool { library.isCropping || library.isSamplingWhiteBalance }

    private var isSheetUp: Binding<Bool> {
        Binding(get: { (tool != nil && !isInCanvasMode) || isInTool },
                set: { if !$0 { tool = nil } })
    }

    /// Compact and medium, or only compact in landscape.
    private var sheetHeights: Set<PresentationDetent> {
        verticalSizeClass == .compact ? [.toolCompact] : [.toolCompact, .medium]
    }

    private var sheetInset: CGFloat {
        guard let sheetTop else { return 0 }
        return max(0, photoAreaBottom - sheetTop)
    }

    private var historySheet: some View {
        NavigationStack {
            HistorySidebar(library: library)
                .navigationTitle("History")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .close) { library.isHistoryShown = false }
                    }
                }
        }
        // The panel's color, as History has beside the photo on the Mac.
        .presentationBackground(Color.interfaceBackground)
        .presentationDetents([.medium, .large])
    }

    /// History, Copy Settings and Export present from the tool's sheet while it is up, since a
    /// view under a presented sheet can't present another.
    private func history(whileSheetIsUp: Bool) -> Binding<Bool> {
        Binding(get: { library.isHistoryShown && (sheetTop != nil) == whileSheetIsUp },
                set: { library.isHistoryShown = $0 })
    }

    private func copySettings(whileSheetIsUp: Bool) -> Binding<Bool> {
        Binding(get: { library.isEditing && library.isChoosingSettingsToCopy && (sheetTop != nil) == whileSheetIsUp },
                set: { if !$0 { library.isChoosingSettingsToCopy = false } })
    }

    private func export(whileSheetIsUp: Bool) -> Binding<Bool> {
        library.exportSheet(presentedWhere: { library.isEditing && (sheetTop != nil) == whileSheetIsUp })
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if library.isCropping {
            PhoneCropToolbar(library: library)
        } else if library.isSamplingWhiteBalance {
            PhoneWhiteBalanceToolbar(library: library) { open(.color) }
        } else if library.isRemovingSpots || library.isMasking {
            // Not reachable from the iPhone's interface until #288, but a keyboard's shortcuts
            // still open them, so they can be left.
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    if library.isRemovingSpots { library.finishRemovingSpots() } else { library.finishMasking() }
                }
            }
        } else {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Share", systemImage: "square.and.arrow.up") {
                    if let photo { library.requestExport(of: [photo]) }
                }
                .disabled(!isEditable || library.exports.isVisible)
            }
            ToolbarItem(placement: .topBarTrailing) { moreMenu }
            // Five buttons of their own, each on its own glass, rather than one grouped control.
            ForEach(Array(PhoneTool.allCases.enumerated()), id: \.element) { index, tool in
                if index > 0 { ToolbarSpacer(.flexible, placement: .bottomBar) }
                ToolbarItem(placement: .bottomBar) {
                    Button(tool.title, systemImage: tool.systemImage) { open(tool) }
                        .disabled(!isEditable || library.selectedEdit == nil)
                }
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Button("Undo", systemImage: "arrow.uturn.backward") { library.undoEdit() }
                    .disabled(!library.canUndoEdit)
                Button("Redo", systemImage: "arrow.uturn.forward") { library.redoEdit() }
                    .disabled(!library.canRedoEdit)
                Button("History", systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90") {
                    library.isHistoryShown = true
                }
                .disabled(!isEditable)
            }
            Section {
                Button("Copy Edits", systemImage: "doc.on.doc") { library.chooseSettingsToCopy() }
                    .disabled(!library.canCopySettings)
                Button("Paste Edits", systemImage: "doc.on.clipboard") {
                    if let photo { library.pasteSettings(to: [photo]) }
                }
                .disabled(!library.canPasteSettings)
            }
            Section {
                Toggle(isOn: Binding(get: { library.browse.isShowingOriginal }, set: { _ in library.toggleOriginal() })) {
                    Label("Compare", systemImage: "square.split.2x1")
                }
                .disabled(!isEditable || library.selectedEdit == nil)
                Toggle(isOn: $isHistogramShown) {
                    Label("Histogram", systemImage: "chart.bar.xaxis")
                }
            }
            Section {
                // One photo reverts without asking, as Undo brings it back. Not destructive, so
                // not red: the interface is black, white and gray.
                Button("Reset", systemImage: "arrow.counterclockwise") {
                    if let photo { library.requestRevert(of: [photo]) }
                }
                .disabled(photo.map { library.photosToRevert(among: [$0]).isEmpty } ?? true)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
    }

    private func open(_ tool: PhoneTool) {
        if tool.hasSheet {
            // Color and Finish open taller, since their segments and top rows leave no room for
            // a slider at the compact height. Landscape has only the compact one.
            sheetHeight = tool.opensAtMediumHeight && verticalSizeClass != .compact ? .medium : .toolCompact
            self.tool = tool
        } else {
            library.startCropping()
        }
    }

    private var photo: PhotoReference? { library.browse.selectedPhoto }

    /// JPEG and HEIC photos aren't edited until #239.
    private var isEditable: Bool { photo?.isEditable != false }
}

/// One tool's sheet: its sliders, or the LUT library for Looks, under the tool's name with Reset
/// and Close, on the tool panel's gray. Color and Finish have segments, named for the Mac's
/// cards, above their sliders, and Reset then resets the segment shown.
private struct ToolSheet: View {
    let library: Library
    let renderer: RAWRenderer?
    let tool: PhoneTool
    let close: () -> Void
    let openEyedropper: () -> Void
    @State private var section: PhoneToolSection?
    /// The color range Selective Color shows.
    @State private var range = ColorRange.red

    init(library: Library, renderer: RAWRenderer?, tool: PhoneTool, close: @escaping () -> Void,
         openEyedropper: @escaping () -> Void) {
        self.library = library
        self.renderer = renderer
        self.tool = tool
        self.close = close
        self.openEyedropper = openEyedropper
        _section = State(initialValue: tool.sections.first)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if tool == .looks {
                        LookSection(library: library, isCard: false)
                    } else if let section {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("Section", selection: Binding(get: { section }, set: { self.section = $0 })) {
                                ForEach(tool.sections) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .padding(.bottom, 4)
                            sectionContent(section)
                        }
                    } else {
                        PhoneToolSliders(library: library, tool: tool)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .disabled(library.selectedEdit == nil)
            }
            // The system's soft edge under the title bar, so sliders fade out beneath it as
            // they scroll rather than meeting it at a hard line.
            .scrollEdgeEffectStyle(.soft, for: .top)
            .background(Color.toolPanel.ignoresSafeArea())
            .navigationTitle(tool.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Reset") { reset() }
                        .disabled(!canReset)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .close, action: close)
                }
            }
        }
        // iOS draws buttons and menus in the accent color, the highlight, which is for small
        // marks of state only (decision 0041).
        .tint(.white)
    }

    /// The segment's groups: a heading in the headline style over its controls and sliders, and a
    /// line between groups, so what belongs together shows without indenting sliders.
    @ViewBuilder private func sectionContent(_ section: PhoneToolSection) -> some View {
        let recipe = library.selectedEdit?.recipe ?? EditRecipe()
        let groups = section.groups(in: recipe, range: range)
        ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
            if index > 0 { Divider() }
            // The heading sits close to its controls; the line and the sheet's spacing set the
            // groups apart.
            VStack(alignment: .leading, spacing: 8) {
                if let title = group.title {
                    Text(title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.controls, id: \.self) { control($0) }
                if !group.sliders.isEmpty {
                    PhoneToolSliders(library: library, adjustments: group.sliders)
                }
            }
        }
    }

    @ViewBuilder private func control(_ control: PhoneSheetControl) -> some View {
        switch control {
        case .blackAndWhite: PhoneBlackAndWhiteRow(library: library)
        case .profile: PhoneProfileRow(library: library)
        // The presets and eyedropper above Temperature and Tint (#298).
        case .whiteBalance: PhoneWhiteBalanceRow(library: library, renderer: renderer, openEyedropper: openEyedropper)
        case .colorRanges: PhoneColorRangePicker(library: library, selected: $range)
        }
    }

    private var canReset: Bool {
        guard let recipe = library.selectedEdit?.recipe else { return false }
        if tool == .looks { return recipe.look != nil }
        return section?.isChanged(in: recipe) ?? tool.isChanged(in: recipe)
    }

    private func reset() {
        library.changeEdit(label: "Reset \(section?.title ?? tool.title)") { recipe in
            if tool == .looks {
                recipe.look = nil
            } else if let section {
                section.reset(in: &recipe)
            } else {
                tool.reset(in: &recipe)
            }
        }
    }
}

private extension Color {
    /// The tool sheets' and histogram's gray: the system's tertiary background, which in the
    /// app's dark interface is about 18% gray, a step lighter than the 13% canvas and close to
    /// the inspector cards' gray on the Mac and iPad.
    static let toolPanel = Color(uiColor: .tertiarySystemBackground)
}

private extension PresentationDetent {
    /// A tool sheet's compact height: its title and the first two sliders, taller at larger text
    /// sizes so the sliders still show.
    static let toolCompact = PresentationDetent.custom(ToolCompactDetent.self)
}

private struct ToolCompactDetent: CustomPresentationDetent {
    static func height(in context: Context) -> CGFloat? {
        PresentationDetent.scaledHeight(212, in: context)
    }
}
