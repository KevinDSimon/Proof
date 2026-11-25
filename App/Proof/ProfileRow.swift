import ProofKit
import ProofUI
import SwiftUI

/// The color profile the photo is decoded with, in the Histogram card under the capture
/// settings: a pop-up when the photo offers the camera maker's embedded profile and Apple's,
/// otherwise the name of the one profile it has.
struct ProfileRow: View {
    let library: Library

    var body: some View {
        let edit = library.selectedEdit
        let profiles = edit?.profiles
        HStack {
            Text("Profile")
                .foregroundStyle(InspectorCard<EmptyView>.labelColor)
            Spacer()
            if let edit, let profiles, profiles.offersChoice {
                Picker("Profile", selection: Binding(
                    get: { edit.recipe.profile },
                    set: { profile in library.changeEdit { $0.profile = profile } })) {
                    ForEach(CameraProfile.allCases, id: \.self) { Text(profiles.label(for: $0)) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .help("The color profile that sets the photo's starting colors")
            } else if let edit, let profiles {
                Text(profiles.label(for: edit.recipe.profile))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
        // Keeps its height while the profiles are read, so the cards below don't jump.
        .frame(minHeight: 22)
        .accessibilityElement(children: profiles?.offersChoice == true ? .contain : .combine)
    }
}
