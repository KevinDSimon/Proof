import ProofKit
import SwiftUI

/// Edit › Copy: which of the photo's settings to copy, as in Lightroom's Copy Settings. Items are
/// grouped by inspector card, each card with a checkbox that ticks or clears all of it. The ticks
/// are remembered for the next copy.
struct CopySettingsSheet: View {
    let library: Library
    @Environment(\.dismiss) private var dismiss
    /// The ticked items' raw values, joined by commas. Empty until the first copy.
    @AppStorage("copySettingsItems") private var storedItems = ""
    @State private var items: Set<SettingsItem> = []

    /// The cards in the inspector's order, split into columns of about equal height, with Crop
    /// (`nil`) beside Transform.
    private static let columns: [[AdjustmentGroup?]] = [
        [.whiteBalance, .basic],
        [.curve, .selectiveColor, .detail, .lens],
        [.transform, nil, .effects, .look],
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Copy Settings")
                    .font(.headline)
                // Transform and Crop fit the photo they came from, so they start unticked.
                Text("Transform and Crop suit photos taken from the same spot, as on a tripod.")
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 32) {
                ForEach(Self.columns, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(column, id: \.self) { group in
                            section(group)
                        }
                    }
                }
            }
            HStack {
                Button("Check All") { items = Set(SettingsItem.allCases) }
                Button("Check None") { items = [] }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Copy") {
                    storedItems = items.map(\.rawValue).sorted().joined(separator: ",")
                    library.copySettings(items)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(items.isEmpty)
            }
        }
        .padding(20)
        .fixedSize()
        .onAppear {
            let stored = Set(storedItems.split(separator: ",").compactMap { SettingsItem(rawValue: String($0)) })
            items = stored.isEmpty ? SettingsItem.defaultItems : stored
        }
    }

    /// A card with one control is a single checkbox. Otherwise the card's checkbox shows a dash
    /// while only some of its items are ticked, and its items are indented under it.
    @ViewBuilder
    private func section(_ group: AdjustmentGroup?) -> some View {
        let groupItems = group.map(SettingsItem.items(in:)) ?? [.crop]
        if groupItems.count == 1 {
            Toggle(Self.title(of: groupItems[0]), isOn: binding(for: groupItems[0]))
                .toggleStyle(.checkbox)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(group.map(Self.title(of:)) ?? "", sources: groupItems.map(binding(for:)), isOn: \.self)
                    .toggleStyle(.checkbox)
                ForEach(groupItems, id: \.self) { item in
                    Toggle(Self.title(of: item), isOn: binding(for: item))
                        .toggleStyle(.checkbox)
                        .padding(.leading, 20)
                }
            }
        }
    }

    private func binding(for item: SettingsItem) -> Binding<Bool> {
        Binding(
            get: { items.contains(item) },
            set: { if $0 { items.insert(item) } else { items.remove(item) } }
        )
    }

    /// The inspector's card titles.
    static func title(of group: AdjustmentGroup) -> String {
        switch group {
        case .whiteBalance: "White Balance"
        case .basic: "Basic"
        case .curve: "Curve"
        case .selectiveColor: "Selective Color"
        case .detail: "Detail"
        case .lens: "Lens Corrections"
        case .transform: "Transform"
        case .effects: "Effects"
        case .look: "Look"
        }
    }

    /// Named after the inspector's sliders and sections, so each item can be found there.
    static func title(of item: SettingsItem) -> String {
        switch item {
        case .whiteBalance: "White Balance"
        case .exposure: "Exposure"
        case .contrast: "Contrast"
        case .highlights: "Highlights"
        case .shadows: "Shadows"
        case .whites: "Whites"
        case .blacks: "Blacks"
        case .texture: "Texture"
        case .clarity: "Clarity"
        case .dehaze: "Dehaze"
        case .treatment: "Treatment"
        case .vibrance: "Vibrance"
        case .saturation: "Saturation"
        case .toneCurve: "Curve"
        case .selectiveColor: "Selective Color"
        case .sharpening: "Sharpening"
        case .noiseReduction: "Noise Reduction"
        case .colorNoiseReduction: "Color Noise Reduction"
        case .lensProfile: "Profile Corrections"
        case .chromaticAberration: "Remove Chromatic Aberration"
        case .distortion: "Distortion"
        case .lensVignetting: "Vignetting"
        case .transform: "Transform"
        case .crop: "Crop"
        case .vignette: "Vignette"
        case .grain: "Grain"
        case .halation: "Halation"
        case .bloom: "Bloom"
        case .look: "Look"
        }
    }
}
