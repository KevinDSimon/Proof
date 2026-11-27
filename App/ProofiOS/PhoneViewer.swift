import ProofKit
import ProofUI
import SwiftUI

/// The photo on iPhone (decision 0055, #286): the photo on the canvas with the filmstrip always
/// under it, and a bottom toolbar of Share, Rating, Info and Edit, each its own Liquid Glass
/// button. A swipe on the photo and a tap on a thumbnail both move the selection, which the
/// filmstrip follows. Edit pushes `PhoneEditor`, whose Back returns here. iPad keeps `PhotoView`.
struct PhoneViewer: View {
    @Bindable var library: Library
    let renderer: RAWRenderer?
    @State private var isEditorShown = false

    var body: some View {
        VStack(spacing: 0) {
            EditPhoto(library: library, renderer: renderer)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(library.canvasColor.color)
            Filmstrip(library: library, photos: library.shownPhotos)
        }
        .background(Color.interfaceBackground.ignoresSafeArea())
        .navigationTitle(library.windowTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .navigationDestination(isPresented: $isEditorShown) {
            PhoneEditor(library: library, renderer: renderer)
        }
        // The viewer stays in the stack under the editor, which presents these itself.
        .sheet(isPresented: Binding(get: { library.isChoosingSettingsToCopy && !isEditorShown },
                                    set: { if !$0 { library.isChoosingSettingsToCopy = false } })) {
            CopySettingsSheet(library: library)
        }
        .sheet(isPresented: library.exportSheet(presentedWhere: { library.isEditing && !isEditorShown })) {
            ExportSheet(library: library)
        }
        // A keyboard's shortcuts can open Crop, Spot Removal and Masks here; their controls and
        // Done are in the editor.
        .onChange(of: isInTool, initial: true) { if isInTool { isEditorShown = true } }
        // Compare is the editor's; the viewer shows the edited photo.
        .onChange(of: isEditorShown) {
            if !isEditorShown, library.browse.isShowingOriginal { library.browse.showEdited() }
        }
    }

    private var isInTool: Bool { library.isCropping || library.isRemovingSpots || library.isMasking }

    /// Share leads, as in Photos, and Edit ends the bar; the flexible spacers give each button its
    /// own glass rather than one grouped control.
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .bottomBar) {
            Button("Share", systemImage: "square.and.arrow.up") {
                if let photo { library.requestExport(of: [photo]) }
            }
            .disabled(!isEditable || library.exports.isVisible)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Menu {
                if let photo {
                    // Written to the photo's XMP sidecar, as the grid's Rating menu is.
                    RatingPicker(library: library, photos: [photo]).pickerStyle(.inline)
                }
            } label: {
                Label("Rating", systemImage: rating > 0 ? "star.fill" : "star")
            }
            .accessibilityValue(RatingBadges.title(ofRating: rating))
            .disabled(photo == nil)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Info", systemImage: "info.circle") { library.infoSheetPhoto = photo }
                .disabled(photo == nil)
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Edit", systemImage: "slider.horizontal.3") { isEditorShown = true }
                .disabled(!isEditable)
        }
    }

    private var photo: PhotoReference? { library.browse.selectedPhoto }

    private var rating: Int { library.selectedPhotoMetadata?.rating ?? 0 }

    /// JPEG and HEIC photos, reached from the filmstrip, aren't edited until #239.
    private var isEditable: Bool { photo?.isEditable == true }
}
