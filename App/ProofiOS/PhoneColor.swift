import ProofKit
import ProofUI
import SwiftUI

/// The Black & White switch at the top of the iPhone Color sheet's Basic segment (#302). It comes
/// first because it changes what the sliders below it do: the red, green and blue mix takes the
/// place of Saturation and Vibrance.
struct PhoneBlackAndWhiteRow: View {
    let library: Library

    var body: some View {
        Toggle("Black & White", isOn: Binding(
            get: { library.selectedEdit?.recipe.blackAndWhite.isOn ?? false },
            set: { isOn in
                // The sheet has no card switches, so this turns Basic on, as a slider does.
                if !library.isOn(.basic) { library.setOn(.basic, true) }
                library.changeEdit { $0.blackAndWhite.isOn = isOn }
            }))
            // Switches are one of the small marks of state the highlight is for (decision 0041).
            .tint(.highlight)
    }
}

/// The color profile the photo is decoded with, as a menu row like the white balance's: Embedded
/// or Apple where the photo offers both, otherwise the name of the one it has.
struct PhoneProfileRow: View {
    let library: Library

    var body: some View {
        let edit = library.selectedEdit
        HStack {
            Text("Camera Profile")
            Spacer()
            if let edit, let profiles = edit.profiles {
                if profiles.offersChoice {
                    Menu {
                        Picker("Camera Profile", selection: Binding(
                            get: { edit.recipe.profile },
                            set: { profile in library.changeEdit { $0.profile = profile } })) {
                            ForEach(CameraProfile.allCases, id: \.self) { Text(profiles.label(for: $0)).tag($0) }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 4) {
                            Text(profiles.label(for: edit.recipe.profile))
                            Image(systemName: "chevron.up.chevron.down")
                                .imageScale(.small)
                        }
                    }
                    .accessibilityLabel("Camera Profile")
                    .accessibilityValue(profiles.label(for: edit.recipe.profile))
                    .accessibilityHint("The color profile that sets the photo's starting colors")
                } else {
                    Text(profiles.label(for: edit.recipe.profile))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        // Keeps its height while the profiles are read, so the rows below don't move.
        .frame(minHeight: 31)
        .accessibilityElement(children: edit?.profiles?.offersChoice == true ? .contain : .combine)
    }
}

/// The eight color ranges of Selective Color as dots in a row, the chosen one ringed, as Proof
/// marks a selection. The Mac's card also has a graph of the photo's hues; on the phone the dots
/// alone choose the range.
struct PhoneColorRangePicker: View {
    let library: Library
    @Binding var selected: ColorRange

    var body: some View {
        let selective = library.selectedEdit?.recipe.selectiveColor ?? SelectiveColor()
        HStack(spacing: 0) {
            ForEach(ColorRange.allCases, id: \.self) { range in
                Button { selected = range } label: {
                    Circle()
                        .fill(SelectiveColorCard.color(hue: range.hue))
                        .frame(width: 22, height: 22)
                        .padding(4)
                        .overlay {
                            if range == selected {
                                Circle().strokeBorder(.white, lineWidth: 2)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(range.title)
                .accessibilityValue(selective[range].isNeutral ? "" : "Changed")
                .accessibilityAddTraits(range == selected ? .isSelected : [])
            }
        }
    }
}
