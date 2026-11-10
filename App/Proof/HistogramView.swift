import ProofKit
import SwiftUI

/// The red, green and blue histogram in the inspector's Histogram section. Each channel is a
/// see-through fill with a solid outline, so every channel's shape stays readable where they
/// overlap. On the dark card the fills add up like light, so where all three overlap they read
/// as gray; on the light card adding would wash them out, so they are simply layered. Like the
/// slider tracks, it shows the photo's colors, so it is an exception to the inspector's gray.
struct HistogramView: View, Equatable {
    var histogram: Histogram?
    @Environment(\.colorScheme) private var colorScheme

    nonisolated static func == (lhs: HistogramView, rhs: HistogramView) -> Bool {
        lhs.histogram == rhs.histogram
    }

    var body: some View {
        Canvas { [colorScheme] context, size in
            guard let histogram else { return }
            let peak = Self.peak(of: histogram)
            let channels = [(histogram.red, Self.red), (histogram.green, Self.green), (histogram.blue, Self.blue)]
            let areas = channels.map { bins, color in (Self.area(of: bins, peak: peak, in: size), color) }
            context.blendMode = colorScheme == .dark ? .plusLighter : .normal
            for (area, color) in areas {
                context.fill(area, with: .color(color.opacity(colorScheme == .dark ? 0.35 : 0.2)))
            }
            context.blendMode = .normal
            for (area, color) in areas {
                context.stroke(area, with: .color(color), lineWidth: 1.25)
            }
        }
        .frame(height: 84)
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(histogram.map(Self.summary) ?? "No photo measured")
    }

    static let red = Color(red: 0.95, green: 0.3, blue: 0.3)
    static let green = Color(red: 0.3, green: 0.85, blue: 0.4)
    static let blue = Color(red: 0.35, green: 0.55, blue: 1)

    /// The tallest bin, leaving out pure black and pure white: a photo with clipped shadows or
    /// highlights has a spike there that would otherwise flatten the rest of the graph.
    static func peak(of histogram: Histogram) -> Float {
        let inner = 1..<(Histogram.binCount - 1)
        let peak = [histogram.red, histogram.green, histogram.blue].map { $0[inner].max() ?? 0 }.max() ?? 0
        return peak > 0 ? peak : 1
    }

    static func area(of bins: [Float], peak: Float, in size: CGSize) -> Path {
        Path { path in
            let step = size.width / CGFloat(bins.count - 1)
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                let height = CGFloat(min(value / peak, 1)) * size.height
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height - height))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
        }
    }

    /// The share of pixels clipped to black or white, which is what the graph shows that matters
    /// most and can be said in words.
    private static func summary(of histogram: Histogram) -> String {
        let channels = [histogram.red, histogram.green, histogram.blue]
        let shadows = channels.map { $0[0] }.max() ?? 0
        let highlights = channels.map { $0[Histogram.binCount - 1] }.max() ?? 0
        let percent = FloatingPointFormatStyle<Float>.Percent().precision(.fractionLength(0...1))
        return "Shadows clipped \(shadows.formatted(percent)), highlights clipped \(highlights.formatted(percent))"
    }
}

/// ISO, focal length, aperture and shutter speed under the histogram, spread across its width
/// as in Lightroom. Each is left out when the photo doesn't record it.
struct CaptureSettingsLine: View {
    var settings: CaptureSettings?

    var body: some View {
        let values = [settings?.formattedISO, settings?.formattedFocalLength,
                      settings?.formattedAperture, settings?.formattedShutterSpeed].compactMap { $0 }
        HStack {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                if index > 0 { Spacer(minLength: 4) }
                Text(value)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        // Keeps its height while the settings are read, so the sliders don't jump.
        .frame(maxWidth: .infinity, minHeight: 14, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
