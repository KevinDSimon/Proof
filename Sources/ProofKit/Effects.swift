/// The Effects card's Grain values, in Lightroom's units.
public struct GrainAdjustments: Codable, Equatable, Sendable {
    /// How strong the grain is. At 0 there is none.
    public var amount: Double = 0
    /// How large each grain is, relative to the photo's size.
    public var size: Double = 25
    /// How uneven the grain is: 0 is soft and even, 100 mixes in finer, sharper grains.
    public var roughness: Double = 50

    public static let amountRange = 0.0...100.0
    public static let sizeRange = 0.0...100.0
    public static let roughnessRange = 0.0...100.0

    private enum CodingKeys: String, CodingKey { case amount, size, roughness }

    public init(amount: Double = 0, size: Double = 25, roughness: Double = 50) {
        self.amount = amount
        self.size = size
        self.roughness = roughness
    }

    /// A missing value reads as its default, as a hand-edited sidecar may leave some out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GrainAdjustments()
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? defaults.amount
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? defaults.size
        roughness = try c.decodeIfPresent(Double.self, forKey: .roughness) ?? defaults.roughness
    }

    public var isNeutral: Bool { self == GrainAdjustments() }
}

/// The Effects card's Halation or Bloom values: light from bright highlights spread over the
/// photo around them.
public struct GlowAdjustments: Codable, Equatable, Sendable {
    /// How much light spreads. At 0 there is none.
    public var amount: Double = 0
    /// How far it spreads, relative to the photo's size.
    public var size: Double = 50

    public static let amountRange = 0.0...100.0
    public static let sizeRange = 0.0...100.0

    private enum CodingKeys: String, CodingKey { case amount, size }

    public init(amount: Double = 0, size: Double = 50) {
        self.amount = amount
        self.size = size
    }

    /// A missing value reads as its default, as a hand-edited sidecar may leave some out.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = GlowAdjustments()
        amount = try c.decodeIfPresent(Double.self, forKey: .amount) ?? defaults.amount
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? defaults.size
    }

    public var isNeutral: Bool { self == GlowAdjustments() }
}
