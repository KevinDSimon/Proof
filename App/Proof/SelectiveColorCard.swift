import ProofKit
import SwiftUI

/// Selective Color: a graph of how much of each hue the photo holds, a row of the eight color
/// ranges, and Hue, Saturation and Brightness for the chosen range. Clicking the graph or a
/// swatch chooses a range; the graph's bars in that range are drawn full, the rest dimmed, and
/// the sliders' tracks follow its color.
///
/// The graph is spaced like the swatches rather than by degrees, so each swatch sits under the
/// hues it adjusts. The ranges' colors are the one exception to the inspector's gray, as the
/// slider tracks and the histogram are: they show the photo's colors.
struct SelectiveColorCard: View {
    let library: Library
    @State private var selected: ColorRange = .red

    var body: some View {
        let selective = library.selectedEdit?.recipe.selectiveColor ?? SelectiveColor()
        InspectorCard(title: "Selective Color", isOn: library.isOnBinding(.selectiveColor),
                      canReset: !selective.isNeutral,
                      reset: { library.changeEdit { $0.selectiveColor = SelectiveColor() } }) {
            HueGraph(hues: library.selectedHistogram?.hues ?? [], selected: $selected)
            RangePicker(selected: $selected, edited: Set(ColorRange.allCases.filter { !selective[$0].isNeutral }))
            slider("Hue", \.hue, track: Self.hueTrack(selected),
                   help: "Turns the \(selected.title.lowercased()) colors toward \(selected.previous.title.lowercased()) or \(selected.next.title.lowercased())")
            slider("Saturation", \.saturation, track: Self.saturationTrack(selected),
                   help: "Mutes the \(selected.title.lowercased()) colors, or makes them more intense")
            slider("Brightness", \.brightness, track: Self.brightnessTrack(selected),
                   help: "Darkens or lightens the \(selected.title.lowercased()) colors")
        }
        .disabled(library.selectedEdit == nil)
    }

    private func slider(_ title: String, _ keyPath: WritableKeyPath<ColorRangeAdjustment, Double>,
                        track: [Color], help: String) -> some View {
        let range = selected
        return AdjustmentSlider(
            title: title,
            spokenTitle: "\(range.title) \(title)",
            value: Binding(get: { library.selectedEdit?.recipe.selectiveColor[range][keyPath: keyPath] ?? 0 },
                           set: { value in library.changeEdit { $0.selectiveColor[range][keyPath: keyPath] = value } }),
            range: ColorRangeAdjustment.range, fineStep: 1, step: 1, coarseStep: 10, fractionDigits: 0,
            showsSign: true, track: track,
            reset: { library.changeEdit { $0.selectiveColor[range][keyPath: keyPath] = 0 } },
            isAdjusting: { library.isAdjusting = $0 })
            .help(help)
    }

    /// A hue in degrees as the swatches and graph draw it.
    static func color(hue: Double, saturation: Double = 0.75, brightness: Double = 0.95) -> Color {
        let turns = (hue / 360).truncatingRemainder(dividingBy: 1)
        return Color(hue: turns < 0 ? turns + 1 : turns, saturation: saturation, brightness: brightness)
    }

    /// The hues the slider reaches, from the previous range's center at −100 to the next's at 100.
    static func hueTrack(_ range: ColorRange) -> [Color] {
        let back = (range.hue - range.previous.hue + 360).truncatingRemainder(dividingBy: 360)
        let ahead = (range.next.hue - range.hue + 360).truncatingRemainder(dividingBy: 360)
        return [-back, -back / 2, 0, ahead / 2, ahead].map { color(hue: range.hue + $0) }
    }

    /// Gray to the range's color.
    static func saturationTrack(_ range: ColorRange) -> [Color] {
        [Color(white: 0.45), color(hue: range.hue, saturation: 0.4, brightness: 0.7), color(hue: range.hue)]
    }

    /// The range's color, dark to light.
    static func brightnessTrack(_ range: ColorRange) -> [Color] {
        [color(hue: range.hue, saturation: 0.6, brightness: 0.3), color(hue: range.hue, saturation: 0.6, brightness: 0.75),
         color(hue: range.hue, saturation: 0.3, brightness: 1)]
    }
}

/// Places hues across the graph so each range's center sits over its swatch, the middle of one
/// of eight equal columns, and the hues between two centers are spread evenly between them.
/// Hues between magenta and red wrap from the right edge to the left.
private enum HueSpacing {
    static let ranges = ColorRange.allCases

    /// From 0 to 1 across the graph.
    static func position(ofHue hue: Double) -> Double {
        let hue = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let centers = ranges.map(\.hue) + [360]
        var index = 0
        for k in 1..<ranges.count where hue >= centers[k] { index = k }
        let t = (hue - centers[index]) / (centers[index + 1] - centers[index])
        let x = (Double(index) + 0.5 + t) / Double(ranges.count)
        return x >= 1 ? x - 1 : x
    }

    /// The range whose column holds `x`, from 0 to 1 across the graph.
    static func range(at x: Double) -> ColorRange {
        ranges[min(max(Int(x * Double(ranges.count)), 0), ranges.count - 1)]
    }
}

/// The photo's hues as bars in their own colors, spaced as the swatches are. Bars in the chosen
/// range are full; the rest are dimmed. Clicking chooses the range under the pointer.
private struct HueGraph: View {
    let hues: [Float]
    @Binding var selected: ColorRange

    /// The tallest a bar can be scaled to, so a nearly gray photo draws a low graph rather than
    /// its few colored pixels at full height: about the height of one bin of a photo whose colors
    /// are all fully saturated and spread evenly.
    private static let minimumPeak: Float = 1 / Float(Histogram.hueBinCount) / 2

    var body: some View {
        Canvas { context, size in
            guard !hues.isEmpty else { return }
            let peak = max(hues.max() ?? 0, Self.minimumPeak)
            let step = 360 / Double(hues.count)
            for (index, value) in hues.enumerated() where value > 0 {
                let start = Double(index) * step, end = start + step
                let hue = start + step / 2
                var x0 = HueSpacing.position(ofHue: start), x1 = HueSpacing.position(ofHue: end)
                // The bin that crosses the right edge is drawn at the edge rather than across.
                if x1 < x0 { x1 = 1 }
                if x1 - x0 > 0.5 { x0 = 0 }
                let height = CGFloat(min(value / peak, 1)) * size.height
                let width = max(CGFloat(x1 - x0) * size.width - 1, 1)
                let rect = CGRect(x: CGFloat(x0) * size.width, y: size.height - height, width: width, height: height)
                let inRange = ColorRange.containing(hue: hue) == selected
                context.fill(Path(rect), with: .color(SelectiveColorCard.color(hue: hue).opacity(inRange ? 1 : 0.3)))
            }
        }
        .frame(height: 72)
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8, style: .continuous))
        .contentShape(.rect)
        .gesture(SpatialTapGesture().onEnded { tap in
            guard width > 0 else { return }
            selected = HueSpacing.range(at: (tap.location.x - 4) / (width - 8))
        })
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .accessibilityElement()
        .accessibilityLabel("Colors in the photo")
        .accessibilityValue(summary)
    }

    @State private var width: CGFloat = 0

    /// The ranges the photo holds most of, for VoiceOver.
    private var summary: String {
        guard !hues.isEmpty else { return "No photo measured" }
        var totals: [ColorRange: Float] = [:]
        let step = 360 / Double(hues.count)
        for (index, value) in hues.enumerated() {
            totals[ColorRange.containing(hue: (Double(index) + 0.5) * step), default: 0] += value
        }
        let top = totals.filter { $0.value > 0.01 }.sorted { $0.value > $1.value }.prefix(3).map(\.key.title)
        return top.isEmpty ? "Mostly gray" : "Mostly " + top.joined(separator: ", ")
    }
}

/// The eight ranges as color swatches in a row, the chosen one marked with a ring, as Proof
/// marks a selection.
private struct RangePicker: View {
    @Binding var selected: ColorRange
    let edited: Set<ColorRange>

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ColorRange.allCases, id: \.self) { range in
                Button { selected = range } label: {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(SelectiveColorCard.color(hue: range.hue))
                        .frame(width: 14, height: 14)
                        .padding(4)
                        .overlay {
                            if range == selected {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(.primary, lineWidth: 2)
                            }
                        }
                    .frame(maxWidth: .infinity)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(range.title)
                .accessibilityLabel(range.title)
                .accessibilityValue(edited.contains(range) ? "Changed" : "")
                .accessibilityAddTraits(range == selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 8, style: .continuous))
    }
}
