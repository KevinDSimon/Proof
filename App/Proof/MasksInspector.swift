import ProofKit
import SwiftUI

/// The Masks tool's controls, which take the inspector's place while the tool is open: the
/// photo's masks, the selected mask's shape, and its own adjustments.
struct MasksInspector: View {
    let library: Library
    let renderer: RAWRenderer?

    @State private var renaming: Int?
    @State private var newName = ""

    var body: some View {
        let layers = library.layers
        InspectorPanel {
            // Adding is a section of its own, apart from the masks already made, so it reads as
            // where new ones come from.
            InspectorCard(title: "Masks", canReset: !layers.isEmpty, reset: library.clearMasks) {
                heading("Add")
                addButtons
                if !layers.isEmpty {
                    heading("Added")
                    VStack(spacing: 2) {
                        ForEach(Array(layers.enumerated()), id: \.offset) { index, layer in
                            row(index, layer)
                        }
                    }
                    Toggle("Show Overlay", isOn: Binding(get: { library.showsMaskOverlay }, set: { library.showsMaskOverlay = $0 }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .tint(.green)
                        .help("Tint the selected mask red on the photo (O). Moving a slider turns it off.")
                }
            }
            if let index = library.selectedLayer, let layer = library.shownLayer {
                shapeCard(index, layer)
                adjustmentsCard(layer.adjustments)
            }
        }
        .alert("Rename Mask", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName.trimmingCharacters(in: .whitespaces)
                if let index = renaming, !name.isEmpty { library.changeLayer(at: index) { $0.name = name } }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    // MARK: Masks card

    private var addButtons: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow {
                addButton(.linear, "Linear", "rectangle.tophalf.inset.filled", "Adjust toward one edge, such as the sky")
                addButton(.radial, "Radial", "circle.dashed", "Adjust inside or outside an ellipse")
            }
            GridRow {
                addButton(.brush, "Brush", "paintbrush.pointed", "Paint where the adjustments apply")
                addButton(.subject, "Subject", "person.crop.rectangle", "Select the photo's main subject")
                    .disabled(renderer == nil || library.isFindingSubject)
                    .overlay(alignment: .trailing) {
                        if library.isFindingSubject {
                            ProgressView().controlSize(.mini).padding(.trailing, 6)
                                .accessibilityLabel("Finding subject")
                        }
                    }
            }
        }
    }

    private func addButton(_ kind: Mask.Kind, _ title: String, _ symbol: String, _ help: String) -> some View {
        Button {
            Task { await library.addMask(kind, with: renderer) }
        } label: {
            Label(title, systemImage: symbol)
                .frame(maxWidth: .infinity)
        }
        .help(help)
        .accessibilityLabel("Add \(kind.title) Mask")
    }

    /// The selected mask's row is inverted, as the interface marks selection without color.
    private func row(_ index: Int, _ layer: Layer) -> some View {
        let isSelected = index == library.selectedLayer
        return HStack(spacing: 8) {
            Image(systemName: Self.symbol(of: layer.mask.kind))
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(layer.name)
                .lineLimit(1)
            Spacer()
            Button {
                library.changeLayer(at: index) { $0.isEnabled.toggle() }
            } label: {
                Image(systemName: layer.isEnabled ? "eye" : "eye.slash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(isSelected ? Color.black : Color.secondary)
            .help(layer.isEnabled ? "Hide this mask's adjustments" : "Show this mask's adjustments")
            .accessibilityLabel(layer.isEnabled ? "Hide \(layer.name)" : "Show \(layer.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .foregroundStyle(isSelected ? Color.black : Color.primary)
        .background(isSelected ? Color.white : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture { library.selectLayer(index) }
        .contextMenu {
            Button("Rename…") {
                newName = layer.name
                renaming = index
            }
            Button("Duplicate") { library.duplicateLayer(at: index) }
            Divider()
            Button("Delete") { library.removeLayer(at: index) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    static func symbol(of kind: Mask.Kind?) -> String {
        switch kind {
        case .linear: "rectangle.tophalf.inset.filled"
        case .radial: "circle.dashed"
        case .brush: "paintbrush.pointed"
        case .subject: "person.crop.rectangle"
        case nil: "questionmark.square.dashed"
        }
    }

    // MARK: Shape card

    @ViewBuilder
    private func shapeCard(_ index: Int, _ layer: Layer) -> some View {
        InspectorCard(title: layer.mask.kind?.title ?? "Mask") {
            switch layer.mask.shape {
            case .linear:
                EmptyView()
            case let .radial(gradient):
                AdjustmentSlider(
                    title: "Feather",
                    value: Binding(get: { gradient.feather }, set: { value in changeRadial(index) { $0.feather = value } }),
                    range: RadialMask.featherRange, fineStep: 1, step: 5, coarseStep: 20, fractionDigits: 0,
                    reset: { changeRadial(index) { $0.feather = RadialMask.defaultFeather } },
                    isAdjusting: { library.isAdjusting = $0 })
            case .brush:
                brushControls
            case .subject:
                Text("The subject Vision found when the mask was added.")
                    .foregroundStyle(.secondary)
            case .unknown:
                Text("This mask was made by a newer version of Proof and has no effect here.")
                    .foregroundStyle(.secondary)
            }
            Toggle("Invert", isOn: Binding(get: { layer.mask.isInverted },
                                           set: { value in library.changeLayer(at: index) { $0.mask.isInverted = value } }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.green)
                .help("Apply the adjustments where the mask doesn't")
            Button {
                library.removeLayer(at: index)
            } label: {
                Text("Delete Mask").frame(maxWidth: .infinity)
            }
            .help("Remove this mask and its adjustments (Delete)")
        }
    }

    private func changeRadial(_ index: Int, _ change: (inout RadialMask) -> Void) {
        library.changeLayer(at: index) { layer in
            guard case var .radial(gradient) = layer.mask.shape else { return }
            change(&gradient)
            layer.mask.shape = .radial(gradient)
        }
    }

    /// The next stroke's settings: strokes already painted keep theirs, as in Lightroom.
    @ViewBuilder
    private var brushControls: some View {
        let stroke = library.nextStroke
        Picker("Brush", selection: Binding(get: { library.isErasing }, set: { library.isErasing = $0 })) {
            Text("Paint").tag(false)
            Text("Erase").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("Paint adds to the mask; Erase takes away from it. Hold Option to switch while painting.")
        AdjustmentSlider(
            title: "Size",
            value: Binding(get: { stroke.radius * pixelsPerRadius }, set: { size in
                library.nextStroke.radius = min(max(size / pixelsPerRadius, BrushStroke.radiusRange.lowerBound),
                                                BrushStroke.radiusRange.upperBound)
            }),
            range: BrushStroke.radiusRange.lowerBound * pixelsPerRadius...BrushStroke.radiusRange.upperBound * pixelsPerRadius,
            fineStep: 1, step: 10, coarseStep: 100, fractionDigits: 0, unit: "pixels",
            // Even steps in ratio, so fine and broad brushes both get room on the track.
            position: { size in
                log(size / pixelsPerRadius / BrushStroke.radiusRange.lowerBound)
                    / log(BrushStroke.radiusRange.upperBound / BrushStroke.radiusRange.lowerBound)
            },
            valueAtPosition: { position in
                BrushStroke.radiusRange.lowerBound * pow(BrushStroke.radiusRange.upperBound / BrushStroke.radiusRange.lowerBound, position)
                    * pixelsPerRadius
            },
            reset: { library.nextStroke.radius = BrushStroke.defaultRadius })
            .help("The brush's width in pixels of the photo ([ and ] on the photo)")
        AdjustmentSlider(
            title: "Feather",
            value: Binding(get: { stroke.feather }, set: { library.nextStroke.feather = $0 }),
            range: BrushStroke.featherRange, fineStep: 1, step: 5, coarseStep: 20, fractionDigits: 0,
            reset: { library.nextStroke.feather = BrushStroke.defaultFeather })
        AdjustmentSlider(
            title: "Flow",
            value: Binding(get: { stroke.flow }, set: { library.nextStroke.flow = $0 }),
            range: BrushStroke.flowRange, fineStep: 1, step: 5, coarseStep: 20, fractionDigits: 0, unit: "%",
            reset: { library.nextStroke.flow = BrushStroke.defaultFlow })
            .help("How much one stroke adds. Painting over it again adds more.")
    }

    /// The photo's pixels across the brush per unit of its radius, so Size is its width in pixels
    /// of the whole photo. A photo whose size isn't known yet is taken as 6000 pixels long.
    private var pixelsPerRadius: Double {
        let size = library.selectedEdit?.size ?? CGSize(width: 6000, height: 4000)
        return 2 * max(size.width, size.height, 1)
    }

    // MARK: Adjustments card

    private func adjustmentsCard(_ adjustments: LocalAdjustments) -> some View {
        InspectorCard(title: "Adjustments", canReset: !adjustments.isNeutral,
                      reset: { library.changeAdjustments { $0 = LocalAdjustments() } }) {
            heading("Color")
            slider("Temperature", \.temperature, adjustments, track: AdjustmentsInspector.temperatureTrack)
            slider("Tint", \.tint, adjustments, track: AdjustmentsInspector.tintTrack)
            heading("Tone")
            AdjustmentSlider(
                title: "Exposure",
                value: Binding(get: { adjustments.exposure },
                               set: { value in library.changeAdjustments { $0.exposure = value } }),
                range: LocalAdjustments.exposureRange, fineStep: 0.01, step: 0.1, coarseStep: 1, fractionDigits: 2,
                showsSign: true, unit: "stops", track: AdjustmentsInspector.exposureTrack,
                reset: { library.changeAdjustments { $0.exposure = 0 } },
                isAdjusting: { library.isAdjusting = $0 })
            slider("Contrast", \.contrast, adjustments, track: AdjustmentsInspector.contrastTrack)
            slider("Highlights", \.highlights, adjustments, track: AdjustmentsInspector.highlightsTrack)
            slider("Shadows", \.shadows, adjustments, track: AdjustmentsInspector.shadowsTrack)
            slider("Whites", \.whites, adjustments, track: AdjustmentsInspector.whitesTrack)
            slider("Blacks", \.blacks, adjustments, track: AdjustmentsInspector.blacksTrack)
            heading("Presence")
            slider("Texture", \.texture, adjustments, track: AdjustmentsInspector.textureTrack)
            slider("Clarity", \.clarity, adjustments, track: AdjustmentsInspector.clarityTrack)
            slider("Dehaze", \.dehaze, adjustments, track: AdjustmentsInspector.dehazeTrack)
            slider("Saturation", \.saturation, adjustments, track: AdjustmentsInspector.saturationTrack)
        }
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<LocalAdjustments, Double>,
                        _ adjustments: LocalAdjustments, track: [Color]) -> some View {
        AdjustmentSlider(
            title: title,
            value: Binding(get: { adjustments[keyPath: keyPath] },
                           set: { value in library.changeAdjustments { $0[keyPath: keyPath] = value } }),
            range: LocalAdjustments.range, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
            showsSign: true, track: track,
            reset: { library.changeAdjustments { $0[keyPath: keyPath] = 0 } },
            isAdjusting: { library.isAdjusting = $0 })
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}
