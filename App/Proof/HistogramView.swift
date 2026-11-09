import ProofKit
import SwiftUI

/// The red, green and blue histogram at the top of the inspector, in a dark well in both
/// appearances. The channels add up like light, so where all three overlap they read as white,
/// as in Lightroom and Photos. Like the slider tracks, it shows the photo's colors, so it is an
/// exception to the inspector's gray.
struct HistogramView: View {
    var histogram: Histogram?

    var body: some View {
        Canvas { context, size in
            guard let histogram else { return }
            let peak = Self.peak(of: histogram)
            context.blendMode = .plusLighter
            for (bins, color) in [(histogram.red, Self.red), (histogram.green, Self.green), (histogram.blue, Self.blue)] {
                context.fill(Self.area(of: bins, peak: peak, in: size), with: .color(color))
            }
        }
        .background(Color(white: 0.13), in: .rect(cornerRadius: 6))
        .clipShape(.rect(cornerRadius: 6))
        .frame(height: 84)
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(histogram.map(Self.summary) ?? "No photo measured")
    }

    private static let red = Color(red: 0.8, green: 0.13, blue: 0.13)
    private static let green = Color(red: 0.13, green: 0.7, blue: 0.13)
    private static let blue = Color(red: 0.16, green: 0.3, blue: 0.9)

    /// The tallest bin, leaving out pure black and pure white: a photo with clipped shadows or
    /// highlights has a spike there that would otherwise flatten the rest of the graph.
    private static func peak(of histogram: Histogram) -> Float {
        let inner = 1..<(Histogram.binCount - 1)
        let peak = [histogram.red, histogram.green, histogram.blue].map { $0[inner].max() ?? 0 }.max() ?? 0
        return peak > 0 ? peak : 1
    }

    private static func area(of bins: [Float], peak: Float, in size: CGSize) -> Path {
        Path { path in
            let step = size.width / CGFloat(bins.count - 1)
            path.move(to: CGPoint(x: 0, y: size.height))
            for (index, value) in bins.enumerated() {
                let height = CGFloat(min(value / peak, 1)) * size.height
                path.addLine(to: CGPoint(x: CGFloat(index) * step, y: size.height - height))
            }
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.closeSubpath()
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
