import CoreImage

/// How a rendered photo's red, green and blue values are spread from black to white, for the
/// histogram at the top of the inspector. Each channel has `binCount` bins holding the fraction
/// of pixels at that level, so a channel's bins add up to 1.
public struct Histogram: Sendable, Equatable {
    public static let binCount = 256

    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]

    public init(red: [Float], green: [Float], blue: [Float]) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// Counts `image` with `CIAreaHistogram`. The image is first converted from the working
    /// space to `colorSpace`, so the bins hold the encoded values the screen shows rather than
    /// linear light. `context` should work in 32-bit float: in half float, bins that hold a few
    /// pixels out of millions lose most of their precision.
    static func measure(_ image: CIImage, colorSpace: CGColorSpace, context: CIContext) -> Histogram? {
        guard let encoded = image.matchedFromWorkingSpace(to: colorSpace) else { return nil }
        let counted = encoded.applyingFilter("CIAreaHistogram", parameters: [
            kCIInputExtentKey: CIVector(cgRect: image.extent),
            "inputCount": binCount,
            kCIInputScaleKey: 1,
        ])
        var bins = [Float](repeating: 0, count: binCount * 4)
        bins.withUnsafeMutableBytes { buffer in
            // No color space: the counts are numbers, not colors, and must not be converted.
            context.render(counted, toBitmap: buffer.baseAddress!, rowBytes: binCount * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: binCount, height: 1), format: .RGBAf, colorSpace: nil)
        }
        func channel(_ offset: Int) -> [Float] {
            let values = stride(from: offset, to: bins.count, by: 4).map { max(bins[$0], 0) }
            let total = values.reduce(0, +)
            return total > 0 ? values.map { $0 / total } : values
        }
        return Histogram(red: channel(0), green: channel(1), blue: channel(2))
    }
}
