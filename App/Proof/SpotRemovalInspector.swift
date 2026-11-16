import ProofKit
import SwiftUI

/// The Spot Removal tool's controls, which take the inspector's place while the tool is open.
/// They change the selected spot, and the settings the next spot gets.
struct SpotRemovalInspector: View {
    let library: Library

    var body: some View {
        let spot = library.shownSpot
        let spots = library.selectedEdit?.recipe.spots ?? []
        InspectorPanel {
            InspectorCard(title: "Spot Removal", canReset: !spots.isEmpty, reset: library.clearSpots) {
                InspectorField("Mode") {
                    Picker("Mode", selection: Binding(get: { spot.mode }, set: { mode in library.changeSpot { $0.mode = mode } })) {
                        Text("Heal").tag(Spot.Mode.heal)
                        Text("Clone").tag(Spot.Mode.clone)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Heal blends the copied area into the color and brightness around the spot. Clone copies it as it is.")
                }
                AdjustmentSlider(
                    title: "Size",
                    value: Binding(get: { spot.radius * pixelsPerRadius }, set: { size in
                        library.changeSpot { $0.radius = min(max(size / pixelsPerRadius, Spot.radiusRange.lowerBound), Spot.radiusRange.upperBound) }
                    }),
                    range: Spot.radiusRange.lowerBound * pixelsPerRadius...Spot.radiusRange.upperBound * pixelsPerRadius,
                    fineStep: 1, step: 5, coarseStep: 25, fractionDigits: 0, unit: "pixels",
                    // Even steps in ratio, so small dust and large blemishes both get room on the track.
                    position: { size in
                        log(size / pixelsPerRadius / Spot.radiusRange.lowerBound)
                            / log(Spot.radiusRange.upperBound / Spot.radiusRange.lowerBound)
                    },
                    valueAtPosition: { position in
                        Spot.radiusRange.lowerBound * pow(Spot.radiusRange.upperBound / Spot.radiusRange.lowerBound, position)
                            * pixelsPerRadius
                    },
                    reset: { library.changeSpot { $0.radius = Spot.defaultRadius } },
                    isAdjusting: { library.isAdjusting = $0 })
                    .help("The spot's width in pixels of the photo ([ and ] on the photo)")
                AdjustmentSlider(
                    title: "Feather",
                    value: Binding(get: { spot.feather }, set: { value in library.changeSpot { $0.feather = value } }),
                    range: Spot.featherRange, fineStep: 1, step: 5, coarseStep: 20, fractionDigits: 0,
                    reset: { library.changeSpot { $0.feather = Spot.defaultFeather } },
                    isAdjusting: { library.isAdjusting = $0 })
                AdjustmentSlider(
                    title: "Opacity",
                    value: Binding(get: { spot.opacity }, set: { value in library.changeSpot { $0.opacity = value } }),
                    range: Spot.opacityRange, fineStep: 1, step: 5, coarseStep: 20, fractionDigits: 0, unit: "%",
                    reset: { library.changeSpot { $0.opacity = Spot.defaultOpacity } },
                    isAdjusting: { library.isAdjusting = $0 })
                HStack {
                    Button {
                        if let index = library.selectedSpot { library.removeSpot(at: index) }
                    } label: {
                        Text("Delete Spot").frame(maxWidth: .infinity)
                    }
                    .disabled(library.selectedSpot == nil)
                    .help("Remove the selected spot (Delete)")
                    Button {
                        library.clearSpots()
                    } label: {
                        Text("Clear All").frame(maxWidth: .infinity)
                    }
                    .disabled(spots.isEmpty)
                    .accessibilityLabel("Clear All Spots")
                    .help("Remove every spot from this photo")
                }
            }
        }
    }

    /// The photo's pixels across a spot per unit of its radius: twice the long edge, so Size is
    /// the spot's width in pixels of the whole photo. A photo whose size isn't known yet is
    /// taken as 6000 pixels long.
    private var pixelsPerRadius: Double {
        let size = library.selectedEdit?.size ?? CGSize(width: 6000, height: 4000)
        return 2 * max(size.width, size.height, 1)
    }
}
