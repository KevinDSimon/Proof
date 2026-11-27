import ProofKit
import ProofUI
import SwiftUI

/// The top of the Lens Corrections group in the iPhone Finish sheet's Detail segment (#302): the
/// lens's correction profile as a menu, and Remove Chromatic Aberration, which Proof measures from
/// the photo, as a switch.
struct PhoneLensSwitches: View {
    let library: Library
    let renderer: RAWRenderer?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) { switches }
    }

    @ViewBuilder private var switches: some View {
        let edit = library.selectedEdit
        let corrections = edit?.recipe.lens ?? LensCorrections()
        // A full-width menu, as Camera Profile is in Color. A photo without a profile, such as
        // a Leica M file, shows the menu dimmed and says so, as the Mac does.
        if let lens = edit?.cameraLens {
            if lens.hasProfile {
                let isOn = corrections.appliesProfile(for: lens)
                Menu {
                    Picker("Lens Profile", selection: Binding(
                        get: { isOn },
                        set: { isOn in
                            switchLensOn()
                            // Back to the decoder's default rather than a saved value when they
                            // match, so the edit stays neutral.
                            library.changeEdit { $0.lens.profile = isOn == lens.profileIsOnByDefault ? nil : isOn }
                        })) {
                        Text("Lens Profile").tag(true)
                        Text("None").tag(false)
                    }
                    .pickerStyle(.inline)
                } label: {
                    PhoneMenuLabel(title: isOn ? "Lens Profile" : "None")
                }
                .phoneMenuStyle()
                .accessibilityLabel("Lens Profile")
                .accessibilityValue(isOn ? "On" : "Off")
                .accessibilityHint("Corrects the lens's distortion and darkened corners with the profile in the photo")
            } else {
                Menu {} label: { PhoneMenuLabel(title: "No Profile for This Photo") }
                    .phoneMenuStyle()
                    .disabled(true)
                    .accessibilityLabel("Lens Profile")
                    .accessibilityValue(lens.name == nil ? "The photo carries no lens correction data"
                                                         : "The photo carries no correction data for this lens")
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
