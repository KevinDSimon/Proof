import Foundation

/// One photo's edit, saved as JSON in `<original file name>.proof` next to the original.
/// The layout is documented in docs/edit-format.md; change both together.
public struct EditRecipe: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let currentProcessVersion = 1

    public var formatVersion: Int
    public var processVersion: Int
    public var basic: BasicAdjustments
    public var curve: ToneCurve
    public var look: Look?
    public var crop: Crop?
    public var layers: [Layer]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, processVersion, basic, curve, look, crop, layers
    }

    public init(
        basic: BasicAdjustments = BasicAdjustments(),
        curve: ToneCurve = ToneCurve(),
        look: Look? = nil,
        crop: Crop? = nil,
        layers: [Layer] = []
    ) {
        formatVersion = Self.currentFormatVersion
        processVersion = Self.currentProcessVersion
        self.basic = basic
        self.curve = curve
        self.look = look
        self.crop = crop
        self.layers = layers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        processVersion = try c.decodeIfPresent(Int.self, forKey: .processVersion) ?? Self.currentProcessVersion
        basic = try c.decodeIfPresent(BasicAdjustments.self, forKey: .basic) ?? BasicAdjustments()
        curve = try c.decodeIfPresent(ToneCurve.self, forKey: .curve) ?? ToneCurve()
        look = try c.decodeIfPresent(Look.self, forKey: .look)
        crop = try c.decodeIfPresent(Crop.self, forKey: .crop)
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
    }

    /// Writes `look` and `crop` as `null` when there are none, so saving over a sidecar that had
    /// one replaces it instead of keeping the old value (see `Sidecar`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(processVersion, forKey: .processVersion)
        try c.encode(basic, forKey: .basic)
        try c.encode(curve, forKey: .curve)
        try c.encode(look, forKey: .look)
        try c.encode(crop, forKey: .crop)
        try c.encode(layers, forKey: .layers)
    }

    /// Whether the edit leaves the photo as it is. The version numbers don't count.
    public var isNeutral: Bool {
        basic.isNeutral && curve == ToneCurve() && look == nil && crop == nil && layers.isEmpty
    }

    /// The sidecar URL for an original photo: the full file name plus `.proof`.
    public static func sidecarURL(for original: URL) -> URL {
        original.deletingLastPathComponent()
            .appendingPathComponent(original.lastPathComponent + ".proof")
    }
}

/// Lightroom-style Basic panel values. Exposure is in stops; the rest run from -100 to 100.
public struct BasicAdjustments: Codable, Equatable, Sendable {
    public var temperature: Double = 0
    public var tint: Double = 0
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0
    public var vibrance: Double = 0
    public var saturation: Double = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        temperature = try value(.temperature)
        tint = try value(.tint)
        exposure = try value(.exposure)
        contrast = try value(.contrast)
        highlights = try value(.highlights)
        shadows = try value(.shadows)
        whites = try value(.whites)
        blacks = try value(.blacks)
        vibrance = try value(.vibrance)
        saturation = try value(.saturation)
    }

    public var isNeutral: Bool { self == BasicAdjustments() }
}

/// Control points per channel, each (input, output) in 0...1, sorted by input.
public struct ToneCurve: Codable, Equatable, Sendable {
    public static let identity: [CurvePoint] = [CurvePoint(0, 0), CurvePoint(1, 1)]

    public var rgb: [CurvePoint] = ToneCurve.identity
    public var red: [CurvePoint] = ToneCurve.identity
    public var green: [CurvePoint] = ToneCurve.identity
    public var blue: [CurvePoint] = ToneCurve.identity

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func points(_ key: CodingKeys) throws -> [CurvePoint] {
            try c.decodeIfPresent([CurvePoint].self, forKey: key) ?? ToneCurve.identity
        }
        rgb = try points(.rgb)
        red = try points(.red)
        green = try points(.green)
        blue = try points(.blue)
    }
}

/// Encoded as a two-element array `[input, output]` to keep sidecars compact.
public struct CurvePoint: Codable, Equatable, Sendable {
    public var input: Double
    public var output: Double

    public init(_ input: Double, _ output: Double) {
        self.input = input
        self.output = output
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        input = try c.decode(Double.self)
        output = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(input)
        try c.encode(output)
    }
}

public struct Look: Codable, Equatable, Sendable {
    /// File name of the LUT in the LUT library.
    public var lut: String
    /// 0 leaves the image unchanged; 1 applies the LUT fully.
    public var strength: Double

    public init(lut: String, strength: Double = 1) {
        self.lut = lut
        self.strength = strength
    }
}

/// Normalized crop rectangle (0...1 of the image) and rotation in degrees.
public struct Crop: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var angle: Double

    public init(x: Double, y: Double, width: Double, height: Double, angle: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.angle = angle
    }
}

/// A mask with its own adjustments. Masks arrive in v1.2; the type exists now so the format doesn't change.
public struct Layer: Codable, Equatable, Sendable {
    public var name: String
    public var isEnabled: Bool
    public var basic: BasicAdjustments

    public init(name: String, isEnabled: Bool = true, basic: BasicAdjustments = BasicAdjustments()) {
        self.name = name
        self.isEnabled = isEnabled
        self.basic = basic
    }
}
