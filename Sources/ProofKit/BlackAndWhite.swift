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

    /// The weights of red, green and blue in the gray, which always add up to 1, so a gray
    /// pixel stays the same gray whatever the mix and the photo's overall brightness holds.
    ///
    /// Each slider adds value ÷ 100 to its channel's weight, and the total added is then taken
    /// back from all three in proportion to luminance. Red at +100 alone makes the gray the red
    /// channel, as a deep red filter does. A weight can go below 0, so a color can be pushed past
    /// the darkest of its channels, as in a channel mixer: a blend of channels that only averaged
    /// them would barely move the muted colors of most photos. Values outside −100…100, which
    /// only a hand-edited sidecar can hold, are clamped.
    public var weights: (red: Double, green: Double, blue: Double) {
        func amount(_ value: Double) -> Double {
            min(max(value, Self.range.lowerBound), Self.range.upperBound) / 100
        }
        let (r, g, b) = (amount(red), amount(green), amount(blue))
        let added = r + g + b
        let l = Self.luminance
        return (l.red + r - added * l.red, l.green + g - added * l.green, l.blue + b - added * l.blue)
    }
}

extension BlackAndWhite {
    /// Colored filters as used on black-and-white film. Each is a starting mix of the three
    /// sliders; the edit stores only the sliders, and a mix that matches a filter's reads as it.
    /// From Yellow to Red each darkens blue skies more and lightens warm tones more; Green
    /// lightens foliage and darkens reds and skin.
    public enum Filter: String, CaseIterable, Sendable {
        case none, yellow, orange, red, green

        public var title: String {
            switch self {
            case .none: "No Filter"
            case .yellow: "Yellow Filter"
            case .orange: "Orange Filter"
            case .red: "Red Filter"
            case .green: "Green Filter"
            }
        }

        /// Red, green and blue for the filter.
        public var mix: (red: Double, green: Double, blue: Double) {
            switch self {
            case .none: (0, 0, 0)
            case .yellow: (15, 0, -15)
            case .orange: (45, 0, -15)
            case .red: (80, -20, -30)
            case .green: (-30, 30, -20)
            }
        }
    }

    /// The filter whose mix the sliders hold, or `nil` for a mix of the person's own.
    public var filter: Filter? {
        Filter.allCases.first { $0.mix == (red, green, blue) }
    }

    /// Sets the sliders to `filter`'s mix.
    public mutating func choose(_ filter: Filter) {
        (red, green, blue) = filter.mix
    }
}

enum BlackAndWhiteStage {
    /// Every channel becomes the same weighted blend of the three, in one `CIColorMatrix`, and
    /// is kept from going below black, which a negative weight can push a color to. Alpha is
    /// left as it is. Off returns the image as is.
    static func apply(_ blackAndWhite: BlackAndWhite, to image: CIImage) -> CIImage {
        guard blackAndWhite.isOn else { return image }
        let w = blackAndWhite.weights
        let row = CIVector(x: w.red, y: w.green, z: w.blue, w: 0)
        return image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": row, "inputGVector": row, "inputBVector": row,
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ]).applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: .greatestFiniteMagnitude, y: .greatestFiniteMagnitude,
                                           z: .greatestFiniteMagnitude, w: 1),
        ])
    }
}
