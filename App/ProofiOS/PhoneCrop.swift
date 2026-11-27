import ProofKit
import ProofUI
import SwiftUI

/// Crop on iPhone (#287): a mode of the editor's canvas rather than a sheet. The touch crop from
/// #229 is on the photo; Straighten sits below it; Rotate, Flip, the aspect ratio, Perspective and
/// Reset take the bottom toolbar's place; Cancel and Done take the navigation bar's. Perspective
/// (#302) swaps Straighten for the Transform sliders, and back. Done and Cancel cover both.
/// iPad keeps `CropInspector` in its inspector.
struct PhoneCropToolbar: ToolbarContent {
    let library: Library
    /// Whether the Transform sliders show below the photo in place of Straighten.
    @Binding var isPerspective: Bool

    var body: some ToolbarContent {
        // Cancel and Done stand in for the rest, so the mode is left only one of two ways.
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { library.cancelCropping() }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button("Done") { library.finishCropping() }
        }
        ToolbarItem(placement: .bottomBar) {
            Button("Rotate", systemImage: "rotate.left") { library.rotate(clockwise: false) }
                .disabled(!isReady)
                .accessibilityHint("Turns the photo a quarter turn counterclockwise")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            Button("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") {
                library.flipHorizontally()
            }
            .disabled(!isReady)
            .accessibilityHint("Mirrors the photo left to right")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) { aspectMenu }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            // Names what a tap shows next, as a button that swaps two views does.
            Button(isPerspective ? "Straighten" : "Perspective",
                   systemImage: isPerspective ? "level" : "perspective") {
                isPerspective.toggle()
            }
            .disabled(!isReady)
            .accessibilityHint(isPerspective ? "Shows Straighten below the photo"
                                             : "Shows the perspective sliders below the photo")
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
        ToolbarItem(placement: .bottomBar) {
            // Resets what is shown: the crop and its turns, or the perspective sliders.
            Button("Reset", systemImage: "arrow.counterclockwise") {
                if isPerspective {
                    library.changeEdit(label: "Reset Perspective") { PhoneTool.crop.reset(in: &$0) }
                } else {
                    library.resetCropRectangle()
                    library.resetCropTurn()
                }
            }
            .disabled(!isReady || !canReset)
        }
    }

    /// The ratios as a picker inside the menu, so the one in use has the system's checkmark, and
    /// the orientation swap below them. Custom ratios are typed on the Mac or iPad; one made there
    /// shows as Custom, checked, but can't be picked here.
    private var aspectMenu: some View {
        Menu {
            Picker("Aspect Ratio", selection: Binding(get: { shownChoice }, set: { library.setCropAspect($0) })) {
                Section {
                    ForEach([AspectChoice.freeform, .original], id: \.self) { Text($0.title).tag($0) }
                }
                Section {
                    ForEach(AspectChoice.allCases.filter { $0.ratio != nil }, id: \.self) { Text($0.title).tag($0) }
                }
                if shownChoice == .custom {
                    Section { Text(AspectChoice.custom.title).tag(AspectChoice.custom) }
                }
            }
            .pickerStyle(.inline)
            Section {
                Button(isPortrait ? "Landscape" : "Portrait",
                       systemImage: isPortrait ? "rectangle" : "rectangle.portrait") {
                    library.swapCropOrientation()
                }
            }
        } label: {
            Label("Aspect Ratio", systemImage: "aspectratio")
        }
        .accessibilityValue(shownChoice.title)
        .disabled(!isReady)
    }

    private var crop: Crop { library.selectedCrop }

    private var shownChoice: AspectChoice {
        AspectChoice.shown(for: crop.aspect, original: library.originalAspect)
    }

    private var isPortrait: Bool {
        library.selectedCropFrame.map { $0.size.height > $0.size.width } ?? false
    }

    private var canReset: Bool {
        if isPerspective { return library.selectedEdit.map { PhoneTool.crop.isChanged(in: $0.recipe) } ?? false }
        return library.canResetCropRectangle || crop.rotation != 0 || crop.flipHorizontal || crop.flipVertical
    }

    /// The photo's size comes from the file, read when it opens.
    private var isReady: Bool { library.turnedPhotoSize != nil }
}

/// The straighten slider below the photo while cropping, in the filmstrip's place.
struct PhoneStraightenSlider: View {
    let library: Library

    var body: some View {
        AdjustmentSlider(
            title: "Straighten",
            value: Binding(get: { library.selectedCrop.angle }, set: { library.setStraighten($0) }),
            range: Crop.angleRange, fineStep: 0.1, step: 0.5, coarseStep: 5, fractionDigits: 1,
            showsSign: true, unit: "degrees",
            reset: { library.setStraighten(0) },
            isAdjusting: { adjusting in
                // Shows the finer grid over the photo while dragging, as on the Mac and iPad.
                library.isStraightening = adjusting
                library.isAdjusting = adjusting
            })
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .disabled(library.turnedPhotoSize == nil)
    }
}

/// The Transform sliders below the photo while cropping, in Straighten's place, when Perspective is
/// on (#302): Vertical, Horizontal, Rotate, Aspect, Scale and the offsets, set by hand. They scroll
/// in a short panel, so the photo keeps most of the screen.
struct PhonePerspectiveSliders: View {
    let library: Library

    var body: some View {
        ScrollView {
            PhoneToolSliders(library: library, adjustments: PhoneTool.crop.adjustments)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        // About two and a half sliders, so the next one shows there is more.
        .frame(height: 190)
        // A scroll view draws on under the bars; the toolbar's buttons sit just below, so the
        // sliders stop at the panel's edge.
        .clipped()
        .disabled(library.turnedPhotoSize == nil)
    }
}
