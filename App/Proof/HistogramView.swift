import ProofKit
import SwiftUI

/// The red, green and blue histogram at the top of the inspector, in a dark well in both
/// appearances, with the camera settings under it. Each channel is a see-through fill with a
/// solid outline, so every channel's shape stays readable where they overlap; the fills add up
/// like light, so where all three overlap they read as gray. Like the slider tracks, it shows
/// the photo's colors, so it is an exception to the inspector's gray.
struct HistogramView: View, Equatable {
    var histogram: Histogram?
    var settings: CaptureSettings?

    var body: some View {
        VStack(spacing: 6) {
            graph
                .frame(height: 84)
                .overlay(alignment: .topLeading) { clippingIndicator(.shadows) }
                .overlay(alignment: .topTrailing) { clippingIndicator(.highlights) }
            info
        }
        .padding(8)
        .background(Color(white: 0.13), in: .rect(cornerRadius: 6))
    }

    private var graph: some View {
        Canvas { context, size in
            guard let histogram else { return }
            let peak = Self.peak(of: histogram)
            context.blendMode = .plusLighter
            let channels = [(histogram.red, Self.red), (histogram.green, Self.green), (histogram.blue, Self.blue)]
            let areas = channels.map { bins, color in (Self.area(of: bins, peak: peak, in: size), color) }
            for (area, color) in areas {
                context.fill(area, with: .color(color.opacity(0.35)))
            }
            context.blendMode = .normal
            for (area, color) in areas {
                context.stroke(area, with: .color(color), lineWidth: 1.25)
            }
        }
        .clipped()
        .accessibilityElement()
        .accessibilityLabel("Histogram")
        .accessibilityValue(histogram.map(Self.summary) ?? "No photo measured")
    }

    /// ISO, focal length, aperture and shutter speed spread across the well, as in Lightroom.
    /// Each is left out when the photo doesn't record it.
    @ViewBuilder private var info: some View {
        let values = [settings?.formattedISO, settings?.formattedFocalLength,
                      settings?.formattedAperture, settings?.formattedShutterSpeed].compactMap { $0 }
        HStack {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                if index > 0 { Spacer(minLength: 4) }
                Text(value)
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(Color(white: 0.7))
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        // Keeps the well's height while the settings are read, so the sliders don't jump.
        .frame(maxWidth: .infinity, minHeight: 14)
        .accessibilityElement(children: .combine)
    }

    private enum End { case shadows, highlights }

    /// A triangle in the graph's top corner that lights up when pixels are clipped to pure black
    /// or pure white, in the color of the channels that clip: white when all three do.
    private func clippingIndicator(_ end: End) -> some View {
        let color = histogram.flatMap { Self.clippingColor(of: $0, at: end) }
        let name = end == .shadows ? "Shadows" : "Highlights"
        return Triangle(pointsLeft: end == .highlights)
            .fill(color ?? Color(white: 0.3))
            .frame(width: 9, height: 9)
            .padding(4)
            .help(color == nil ? "No \(name.lowercased()) clipped" : "\(name) clipped")
            .accessibilityHidden(true)
    }

    /// Ignores the odd clipped pixel, such as a dead or hot photosite, which would keep the
    /// indicator lit on almost every photo.
    private static let clippingThreshold: Float = 0.0001

    private static func clippingColor(of histogram: Histogram, at end: End) -> Color? {
        let bin = end == .shadows ? 0 : Histogram.binCount - 1
        let clipped = [histogram.red, histogram.green, histogram.blue].map { $0[bin] > clippingThreshold }
        guard clipped.contains(true) else { return nil }
        return Color(red: clipped[0] ? 1 : 0.25, green: clipped[1] ? 1 : 0.25, blue: clipped[2] ? 1 : 0.25)
    }

    private static let red = Color(red: 0.95, green: 0.3, blue: 0.3)
    private static let green = Color(red: 0.3, green: 0.85, blue: 0.4)
    private static let blue = Color(red: 0.35, green: 0.55, blue: 1)

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

/// A right triangle filling the corner it sits in, its square corner outward.
private struct Triangle: Shape {
    var pointsLeft: Bool

    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: pointsLeft ? CGPoint(x: rect.maxX, y: rect.maxY) : CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
