import ProofKit
import SwiftUI

/// The color profile the photo is decoded with, in the Histogram card under the capture
/// settings: a pop-up when the photo offers the camera maker's embedded profile and Apple's,
/// otherwise the name of the one profile it has.
public struct ProfileRow: View {
    let library: Library
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(library: Library) {
        self.library = library
    }

    public var body: some View {
        let edit = library.selectedEdit
        let profiles = edit?.profiles
        // At the accessibility text sizes the pop-up goes under its name, where it has the card's width.
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading))
                                                          : AnyLayout(HStackLayout())
        layout {
            Text("Profile")
                .inspectorLabelStyle()
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            if let edit, let profiles, profiles.offersChoice {
                Picker("Profile", selection: Binding(
                    get: { edit.recipe.profile },
                    set: { profile in library.changeEdit { $0.profile = profile } })) {
                    ForEach(CameraProfile.allCases, id: \.self) { Text(profiles.label(for: $0)) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: dynamicTypeSize.isAccessibilitySize)
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
