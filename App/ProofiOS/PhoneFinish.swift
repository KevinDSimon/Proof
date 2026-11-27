import ProofKit
import ProofUI
import SwiftUI

/// The switches of the Lens Corrections section in the iPhone Finish sheet's Detail segment
/// (#302): the lens's correction profile, and Remove Chromatic Aberration, which Proof measures
/// from the photo. A photo without a profile says so in place of its switch, as on the Mac.
struct PhoneLensSwitches: View {
    let library: Library
    let renderer: RAWRenderer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { switches }
    }

    @ViewBuilder private var switches: some View {
        let edit = library.selectedEdit
        let corrections = edit?.recipe.lens ?? LensCorrections()
        if let lens = edit?.cameraLens {
            if lens.hasProfile {
                Toggle("Profile Corrections", isOn: Binding(
                    get: { corrections.appliesProfile(for: lens) },
                    set: { isOn in
                        switchLensOn()
                        // Back to the decoder's default rather than a saved value when they
                        // match, so the edit stays neutral.
                        library.changeEdit { $0.lens.profile = isOn == lens.profileIsOnByDefault ? nil : isOn }
                    }))
                    .tint(.highlight)
                    .accessibilityHint("Corrects the lens's distortion and darkened corners with the profile in the photo")
            } else {
                LabeledContent("Profile", value: "None for this photo")
            }
        }
        Toggle(isOn: Binding(
            get: { corrections.chromaticAberration != nil || library.isMeasuringChromaticAberration },
            set: { isOn in
                guard let renderer else { return }
                switchLensOn()
                Task { await library.setRemovesChromaticAberration(isOn, with: renderer) }
            })) {
            HStack {
                Text("Remove Chromatic Aberration")
                if library.isMeasuringChromaticAberration {
                    ProgressView()
                        .accessibilityLabel("Measuring")
                }
            }
        }
        .tint(.highlight)
        .accessibilityHint("Lines up the red and blue fringes along edges, measured from this photo")
        .disabled(renderer == nil || library.isAutoAdjusting)
    }

    /// The sheet has no card switches, so a lens switch turns the card on, as a slider does.
    private func switchLensOn() {
        if !library.isOn(.lens) { library.setOn(.lens, true) }
    }
}
