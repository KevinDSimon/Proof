import CoreImage

/// The Basic card's Treatment, Color or Black & White, and the black-and-white mix: how much the
/// photo's red, green and blue channels each contribute to the gray, as color filters do on
/// black-and-white film. See docs/decisions/0027-black-and-white.md.
public struct BlackAndWhite: Codable, Equatable, Sendable {
    public static let range: ClosedRange<Double> = -100...100

    /// Black & White when true. The mix is kept while it is false, for switching back.
    public var isOn = false
    /// From −100 to 100. Raising one lightens everything that holds that channel and darkens
    /// the rest; at 0 all three, the gray is the photo's luminance.
    public var red: Double = 0
    public var green: Double = 0
    public var blue: Double = 0

    public init(isOn: Bool = false, red: Double = 0, green: Double = 0, blue: Double = 0) {
        self.isOn = isOn
        self.red = red
        self.green = green
        self.blue = blue
    }

    private enum CodingKeys: String, CodingKey { case isOn, red, green, blue }

    /// A missing value reads as off or 0, as a hand-edited sidecar may leave some out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isOn = try c.decodeIfPresent(Bool.self, forKey: .isOn) ?? false
        red = try c.decodeIfPresent(Double.self, forKey: .red) ?? 0
        green = try c.decodeIfPresent(Double.self, forKey: .green) ?? 0
        blue = try c.decodeIfPresent(Double.self, forKey: .blue) ?? 0
    }

    /// Whether the photo keeps its color. The mix doesn't render while it does.
    public var isNeutral: Bool { !isOn }

    /// Rec. 709 luminance weights for linear sRGB primaries, the working space's.
    static let luminance = (red: 0.2126, green: 0.7152, blue: 0.0722)

    /// A slider at ±100 multiplies its channel's weight by this, or divides it.
    static let maximumFactor = 4.0

    /// The weights of red, green and blue in the gray, which always add up to 1, so a gray
    /// pixel stays the same gray whatever the mix and the photo's overall brightness holds.
    /// Values outside −100…100, which only a hand-edited sidecar can hold, are clamped.
    public var weights: (red: Double, green: Double, blue: Double) {
        func factor(_ value: Double) -> Double {
            pow(Self.maximumFactor, min(max(value, Self.range.lowerBound), Self.range.upperBound) / 100)
        }
        let r = Self.luminance.red * factor(red)
        let g = Self.luminance.green * factor(green)
        let b = Self.luminance.blue * factor(blue)
        let sum = r + g + b
        return (r / sum, g / sum, b / sum)
    }
}

enum BlackAndWhiteStage {
    /// Every channel becomes the same weighted blend of the three, in one `CIColorMatrix`.
    /// Alpha is left as it is. Off returns the image as is.
    static func apply(_ blackAndWhite: BlackAndWhite, to image: CIImage) -> CIImage {
        guard blackAndWhite.isOn else { return image }
        let w = blackAndWhite.weights
        let row = CIVector(x: w.red, y: w.green, z: w.blue, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": row, "inputGVector": row, "inputBVector": row,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
    }
}
