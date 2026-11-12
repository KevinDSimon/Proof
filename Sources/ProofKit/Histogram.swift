import CoreImage

/// How a rendered photo's red, green and blue values are spread from black to white, for the
/// histogram at the top of the inspector. Each channel has `binCount` bins holding the fraction
/// of pixels at that level, so a channel's bins add up to 1.
public struct Histogram: Sendable, Equatable {
    public static let binCount = 256

    public let red: [Float]
    public let green: [Float]
    public let blue: [Float]
    /// How much of each hue the photo holds, for the Selective Color graph: `hueBinCount` bins
    /// around the hue circle from red at 0°, each pixel counted by its saturation, so grays add
    /// nothing. The hues are those `SelectiveColorStage` sees, so a bin falls in the range that
    /// adjusts it. The bins add up to the photo's average saturation, not to 1, so a muted photo
    /// draws a low graph. Empty when not measured.
    public let hues: [Float]

    public static let hueBinCount = 120

    public init(red: [Float], green: [Float], blue: [Float], hues: [Float] = []) {
        self.red = red
        self.green = green
        self.blue = blue
        self.hues = hues
    }

    /// Counts `image` with `CIAreaHistogram`. The image is first converted from the working
    /// space to `colorSpace`, so the bins hold the encoded values the screen shows rather than
    /// linear light. `context` should work in 32-bit float: in half float, bins that hold a few
    /// pixels out of millions lose most of their precision. The hues are counted in `hues`
    /// when given, and otherwise in `image`.
    static func measure(_ image: CIImage, hues: CIImage? = nil, colorSpace: CGColorSpace, context: CIContext) -> Histogram? {
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
        return Histogram(red: channel(0), green: channel(1), blue: channel(2),
                         hues: measureHues(hues ?? image, context: context))
    }

    /// The long edge of the copy the hues are counted in: enough for the graph's bars, and
    /// cheap enough to count on the CPU.
    static let hueSampleSize: CGFloat = 256

    /// Counts hues in a small copy of `image`, encoded with a 2.2 gamma in linear sRGB's
    /// primaries, as `SelectiveColorStage` finds them.
    static func measureHues(_ image: CIImage, context: CIContext) -> [Float] {
        let extent = image.extent
        guard extent.width >= 1, extent.height >= 1, !extent.isInfinite else { return [] }
        let scale = min(hueSampleSize / max(extent.width, extent.height), 1)
        let small = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
        let width = max(Int(small.extent.width), 1), height = max(Int(small.extent.height), 1)
        var pixels = [Float](repeating: 0, count: width * height * 4)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        pixels.withUnsafeMutableBytes { buffer in
            context.render(small, toBitmap: buffer.baseAddress!, rowBytes: width * 4 * MemoryLayout<Float>.size,
                           bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: linear)
        }
        var bins = [Float](repeating: 0, count: hueBinCount)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            guard let (hue, saturation) = hueAndSaturation(pixels[index], pixels[index + 1], pixels[index + 2]) else { continue }
            bins[min(Int(hue / 360 * Float(hueBinCount)), hueBinCount - 1)] += saturation
        }
        let count = Float(width * height)
        return bins.map { $0 / count }
    }

    /// The HSV hue in degrees and saturation of a linear color after a 2.2 gamma, or `nil` for a
    /// gray, which has no hue.
    static func hueAndSaturation(_ r: Float, _ g: Float, _ b: Float) -> (hue: Float, saturation: Float)? {
        let (r, g, b) = (pow(max(r, 0), 1 / 2.2), pow(max(g, 0), 1 / 2.2), pow(max(b, 0), 1 / 2.2))
        let v = max(r, g, b), c = v - min(r, g, b)
        guard v > 0, c > 0 else { return nil }
        var h: Float
        if v == r { h = ((g - b) / c + 6).truncatingRemainder(dividingBy: 6) }
        else if v == g { h = (b - r) / c + 2 }
        else { h = (r - g) / c + 4 }
        h *= 60
        return (h, c / v)
    }
}
