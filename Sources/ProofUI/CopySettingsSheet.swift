import ProofKit
import SwiftUI

/// Edit › Copy: which of the photo's settings to copy, as in Lightroom's Copy Settings. Items are
/// grouped by inspector card, each card with a checkbox that ticks or clears all of it. The ticks
/// are remembered for the next copy. iPad and iPhone list the same items with switches (#233).
public struct CopySettingsSheet: View {
    let library: Library
    @Environment(\.dismiss) private var dismiss
    /// The ticked items' raw values, joined by commas. Empty until the first copy.
    @AppStorage("copySettingsItems") private var storedItems = ""
    @State private var items: Set<SettingsItem> = []

    /// The sheet's groups split into columns of about equal height, with Profile above them.
    private static let columns: [[AdjustmentGroup?]] = [
        Array(SettingsItem.sheetGroups[0..<3]),
        Array(SettingsItem.sheetGroups[3..<7]),
        Array(SettingsItem.sheetGroups[7...]),
    ]

    // Transform, Crop, Spot Removal and Masks fit the photo they came from, so they start unticked.
    private static let explanation = "Transform and Crop suit photos taken from the same spot, as on a tripod. Spot Removal suits photos with the same sensor dust, and Masks photos framed alike."

    public init(library: Library) {
        self.library = library
    }

    public var body: some View {
        #if os(macOS)
        columnsLayout
            .onAppear(perform: restoreItems)
        #else
        listLayout
            .onAppear(perform: restoreItems)
        #endif
    }

    private func restoreItems() {
        let stored = Set(storedItems.split(separator: ",").compactMap { SettingsItem(rawValue: String($0)) })
        items = stored.isEmpty ? SettingsItem.defaultItems : stored
    }

    private func copy() {
        storedItems = items.map(\.rawValue).sorted().joined(separator: ",")
        library.copySettings(items)
        dismiss()
    }

    #if os(macOS)
    private var columnsLayout: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Copy Settings")
                    .font(.headline)
                Text(Self.explanation)
                    .foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 32) {
                ForEach(Self.columns, id: \.self) { column in
                    VStack(alignment: .leading, spacing: 12) {
                        // Profile has no card of its own or switch; it sits in the Histogram card.
                        if column == Self.columns[0] {
                            Toggle(Self.title(of: .profile), isOn: binding(for: .profile))
                        }
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
                Button("Copy", action: copy)
                    .keyboardShortcut(.defaultAction)
                    .disabled(items.isEmpty)
            }
        }
        .padding(20)
        .fixedSize()
    }

    /// A card with one control is a single checkbox. Otherwise the card's checkbox shows a dash
    /// while only some of its items are ticked, and its items are indented under it.
    @ViewBuilder
    private func section(_ group: AdjustmentGroup?) -> some View {
        let groupItems = SettingsItem.items(inSheetGroup: group)
        if group == nil {
            // Tools rather than cards, each a checkbox of its own.
            VStack(alignment: .leading, spacing: 12) {
                ForEach(groupItems, id: \.self) { item in
                    Toggle(Self.title(of: item), isOn: binding(for: item))
                        .checkboxOnMac()
                }
            }
        } else if groupItems.count == 1 {
            Toggle(Self.title(of: groupItems[0]), isOn: binding(for: groupItems[0]))
                .checkboxOnMac()
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Toggle(group.map(Self.title(of:)) ?? "", sources: groupItems.map(binding(for:)), isOn: \.self)
                    .checkboxOnMac()
                ForEach(groupItems, id: \.self) { item in
                    Toggle(Self.title(of: item), isOn: binding(for: item))
                        .checkboxOnMac()
                        .padding(.leading, 20)
                }
            }
        }
    }

    #else
    /// One list, as in Settings: cards with several items under their title, with a button that
    /// turns all of them on or off, and the cards with one item gathered in sections of their own
    /// between them, so no section holds a single switch under its own name.
    private var listLayout: some View {
        NavigationStack {
            List {
                ForEach(Self.listSections, id: \.self) { section in
                    Section {
                        ForEach(section.items, id: \.self) { item in
                            Toggle(Self.title(of: item), isOn: binding(for: item))
                                .tint(.highlight)
                        }
                    } header: {
                        if let group = section.card {
                            cardHeader(group, items: section.items)
                        }
                    } footer: {
                        if section.items.contains(.transform) {
                            Text(Self.explanation)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.sheetBackground)
            .navigationTitle("Copy Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() }
                }
                // Plain, not a confirming role: that takes the highlight as a fill (decision 0041).
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Copy", action: copy)
                        .disabled(items.isEmpty)
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Turn All On") { items = Set(SettingsItem.allCases) }
                        .disabled(items.count == SettingsItem.allCases.count)
                    Spacer()
                    Button("Turn All Off") { items = [] }
                        .disabled(items.isEmpty)
                }
            }
        }
        .presentationBackground(Color.sheetBackground)
        // iOS draws buttons in the accent color, the highlight, which is for marks of state only.
        .tint(.white)
    }

    private struct ListSection: Hashable {
        /// The card whose title heads the section; `nil` for a section of single items.
        var card: AdjustmentGroup?
        var items: [SettingsItem]
    }

    /// Profile and the sheet's groups in order, with the cards of one item and the tools run
    /// together between the cards of several.
    private static let listSections: [ListSection] = {
        var sections = [ListSection(card: nil, items: [.profile])]
        for group in SettingsItem.sheetGroups {
            let groupItems = SettingsItem.items(inSheetGroup: group)
            if let group, groupItems.count > 1 {
                sections.append(ListSection(card: group, items: groupItems))
            } else if sections[sections.count - 1].card == nil {
                sections[sections.count - 1].items += groupItems
            } else {
                sections.append(ListSection(card: nil, items: groupItems))
            }
        }
        return sections
    }()

    private func cardHeader(_ group: AdjustmentGroup, items groupItems: [SettingsItem]) -> some View {
        let allOn = Set(groupItems).isSubset(of: items)
        return HStack {
            Text(Self.title(of: group))
            Spacer()
            Button(allOn ? "Turn Off" : "Turn On") {
                if allOn { items.subtract(groupItems) } else { items.formUnion(groupItems) }
            }
            .font(.subheadline)
            .textCase(nil)
            .accessibilityLabel(allOn ? "Turn Off \(Self.title(of: group))" : "Turn On \(Self.title(of: group))")
        }
    }
    #endif

    private func binding(for item: SettingsItem) -> Binding<Bool> {
        Binding(
            get: { items.contains(item) },
            set: { if $0 { items.insert(item) } else { items.remove(item) } }
        )
    }

    /// The inspector's card titles.
    public static func title(of group: AdjustmentGroup) -> String {
        group.title
    }

    /// Named after the inspector's sliders and sections, so each item can be found there.
    public static func title(of item: SettingsItem) -> String {
        switch item {
        case .profile: "Profile"
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
        case .spotRemoval: "Spot Removal"
        case .masks: "Masks"
        case .vignette: "Vignette"
        case .grain: "Grain"
        case .halation: "Halation"
        case .bloom: "Bloom"
        case .look: "Look"
        }
    }
}

#if os(macOS)
private extension View {
    func checkboxOnMac() -> some View {
        toggleStyle(.checkbox)
    }
}
#endif
