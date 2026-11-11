import CoreImage
import Foundation

/// One photo's edit, saved as JSON in `<original file name>.proof` next to the original.
/// The layout is documented in docs/edit-format.md; change both together.
public struct EditRecipe: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 3
    public static let currentProcessVersion = 1

    public var formatVersion: Int
    public var processVersion: Int
    public var basic: BasicAdjustments
    public var curve: ToneCurve
    public var detail: DetailAdjustments
    public var look: Look?
    public var vignette: VignetteAdjustments
    public var lens: LensCorrections
    public var crop: Crop?
    public var layers: [Layer]

    private enum CodingKeys: String, CodingKey {
        case formatVersion, processVersion, basic, curve, detail, look, vignette, lens, crop, layers
    }

    public init(
        basic: BasicAdjustments = BasicAdjustments(),
        curve: ToneCurve = ToneCurve(),
        detail: DetailAdjustments = DetailAdjustments(),
        look: Look? = nil,
        vignette: VignetteAdjustments = VignetteAdjustments(),
        lens: LensCorrections = LensCorrections(),
        crop: Crop? = nil,
        layers: [Layer] = []
    ) {
        formatVersion = Self.currentFormatVersion
        processVersion = Self.currentProcessVersion
        self.basic = basic
        self.curve = curve
        self.detail = detail
        self.look = look
        self.vignette = vignette
        self.lens = lens
        self.crop = crop
        self.layers = layers
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        processVersion = try c.decodeIfPresent(Int.self, forKey: .processVersion) ?? Self.currentProcessVersion
        basic = try c.decodeIfPresent(BasicAdjustments.self, forKey: .basic) ?? BasicAdjustments()
        curve = try c.decodeIfPresent(ToneCurve.self, forKey: .curve) ?? ToneCurve()
        // Edits saved before the Detail card have no `detail`, which keeps the camera's sharpening
        // and noise reduction, as they always rendered.
        detail = try c.decodeIfPresent(DetailAdjustments.self, forKey: .detail) ?? DetailAdjustments()
        look = try c.decodeIfPresent(Look.self, forKey: .look)
        // Edits saved before the Vignette card have none.
        vignette = try c.decodeIfPresent(VignetteAdjustments.self, forKey: .vignette) ?? VignetteAdjustments()
        // Edits saved before Lens Corrections keep the decoder's default, as they always rendered.
        lens = try c.decodeIfPresent(LensCorrections.self, forKey: .lens) ?? LensCorrections()
        crop = try c.decodeIfPresent(Crop.self, forKey: .crop)
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        // Format 1 held temperature and tint as −100 to 100 offsets. Nothing rendered them, so
        // they are dropped and the photo keeps the camera's white balance, as it always showed.
        if formatVersion < 2 {
            basic.resetWhiteBalance()
            for index in layers.indices { layers[index].basic.resetWhiteBalance() }
        }
        // Format 2 had no turn, flips or ratio in `crop`, which read as none. No version of Proof
        // wrote or rendered a format 2 crop, so its rectangle and angle are kept as they are.
        formatVersion = Self.currentFormatVersion
    }

    /// Writes `look` and `crop` as `null` when there are none, so saving over a sidecar that had
    /// one replaces it instead of keeping the old value (see `Sidecar`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(formatVersion, forKey: .formatVersion)
        try c.encode(processVersion, forKey: .processVersion)
        try c.encode(basic, forKey: .basic)
        try c.encode(curve, forKey: .curve)
        try c.encode(detail, forKey: .detail)
        try c.encode(look, forKey: .look)
        try c.encode(vignette, forKey: .vignette)
        try c.encode(lens, forKey: .lens)
        try c.encode(crop, forKey: .crop)
        try c.encode(layers, forKey: .layers)
    }

    /// Whether the edit leaves the photo as it is. The version numbers don't count.
    public var isNeutral: Bool {
        basic.isNeutral && curve == ToneCurve() && detail.isNeutral && look == nil && vignette.isNeutral && lens.isNeutral && (crop?.isIdentity ?? true) && layers.isEmpty
    }

    /// The photo without its adjustments, for Show Original: lens corrections and the crop, with
    /// its turns and flips, are kept, so the comparison frames the same picture. Geometry added
    /// later belongs here too.
    public var original: EditRecipe {
        var original = EditRecipe()
        original.processVersion = processVersion
        original.lens = lens
        original.crop = crop
        return original
    }

    /// The sidecar URL for an original photo: the full file name plus `.proof`.
    public static func sidecarURL(for original: URL) -> URL {
        original.deletingLastPathComponent()
            .appendingPathComponent(original.lastPathComponent + ".proof")
    }
}

/// Lightroom-style Basic panel values. White balance is in Kelvin and tint, `nil` for the
/// camera's own (As Shot); exposure is in stops; the rest run from -100 to 100.
public struct BasicAdjustments: Codable, Equatable, Sendable {
    /// The white balance menu's choice. It labels `temperature` and `tint`; only they render.
    public var whiteBalance: WhiteBalancePreset = .asShot
    /// Kelvin, `nil` for the camera's.
    public var temperature: Double?
    /// Green (negative) to magenta (positive), `nil` for the camera's.
    public var tint: Double?
    public var exposure: Double = 0
    public var contrast: Double = 0
    public var texture: Double = 0
    public var clarity: Double = 0
    public var dehaze: Double = 0
    public var highlights: Double = 0
    public var shadows: Double = 0
    public var whites: Double = 0
    public var blacks: Double = 0
    public var vibrance: Double = 0
    public var saturation: Double = 0

    private enum CodingKeys: String, CodingKey {
        case whiteBalance, temperature, tint, exposure, contrast, texture, clarity, dehaze, highlights, shadows, whites, blacks, vibrance, saturation
    }

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value(_ key: CodingKeys) throws -> Double { try c.decodeIfPresent(Double.self, forKey: key) ?? 0 }
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature)
        tint = try c.decodeIfPresent(Double.self, forKey: .tint)
        // A preset this version doesn't know still renders by its values, so it reads as Custom.
        let preset = try c.decodeIfPresent(String.self, forKey: .whiteBalance)
        whiteBalance = preset.map { WhiteBalancePreset(rawValue: $0) ?? .custom } ?? (temperature == nil && tint == nil ? .asShot : .custom)
        exposure = try value(.exposure)
        contrast = try value(.contrast)
        texture = try value(.texture)
        clarity = try value(.clarity)
        dehaze = try value(.dehaze)
        highlights = try value(.highlights)
        shadows = try value(.shadows)
        whites = try value(.whites)
        blacks = try value(.blacks)
        vibrance = try value(.vibrance)
        saturation = try value(.saturation)
    }

    /// Writes As Shot's `nil` temperature and tint as `null`, so saving over a sidecar that had
    /// values replaces them instead of keeping the old ones (see `Sidecar`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(whiteBalance, forKey: .whiteBalance)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(tint, forKey: .tint)
        try c.encode(exposure, forKey: .exposure)
        try c.encode(contrast, forKey: .contrast)
        try c.encode(texture, forKey: .texture)
        try c.encode(clarity, forKey: .clarity)
        try c.encode(dehaze, forKey: .dehaze)
        try c.encode(highlights, forKey: .highlights)
        try c.encode(shadows, forKey: .shadows)
        try c.encode(whites, forKey: .whites)
        try c.encode(blacks, forKey: .blacks)
        try c.encode(vibrance, forKey: .vibrance)
        try c.encode(saturation, forKey: .saturation)
    }

    public var isNeutral: Bool { self == BasicAdjustments() }

    /// Back to the camera's white balance.
    public mutating func resetWhiteBalance() {
        whiteBalance = .asShot
        temperature = nil
        tint = nil
    }

    /// Chooses from the white balance menu. A preset sets its Kelvin with no tint. Custom isn't
    /// chosen; it is what the menu shows once a slider has moved. Auto needs the photo, so it
    /// is set with `setAuto(_:)`.
    public mutating func choose(_ preset: WhiteBalancePreset) {
        switch preset {
        case .asShot: resetWhiteBalance()
        case .auto, .custom: break
        default:
            temperature = preset.temperature
            tint = 0
            whiteBalance = preset
        }
    }

    /// Sets the white balance Auto estimated for the photo, which the menu shows as Auto.
    public mutating func setAuto(_ found: WhiteBalance) {
        temperature = min(max(found.temperature, WhiteBalance.temperatureRange.lowerBound), WhiteBalance.temperatureRange.upperBound)
        tint = min(max(found.tint, WhiteBalance.tintRange.lowerBound), WhiteBalance.tintRange.upperBound)
        whiteBalance = .auto
    }

    /// Sets the temperature from a slider or the value field, which makes the white balance Custom.
    public mutating func setTemperature(_ kelvin: Double) {
        temperature = min(max(kelvin, WhiteBalance.temperatureRange.lowerBound), WhiteBalance.temperatureRange.upperBound)
        whiteBalance = .custom
    }

    /// Sets the tint from a slider or the value field, which makes the white balance Custom.
    public mutating func setTint(_ value: Double) {
        tint = min(max(value, WhiteBalance.tintRange.lowerBound), WhiteBalance.tintRange.upperBound)
        whiteBalance = .custom
    }

    /// Puts the camera's temperature back. With the tint also the camera's, that is As Shot.
    public mutating func resetTemperature() {
        temperature = nil
        if tint == nil { whiteBalance = .asShot } else { whiteBalance = .custom }
    }

    /// Puts the camera's tint back. With the temperature also the camera's, that is As Shot.
    public mutating func resetTint() {
        tint = nil
        if temperature == nil { whiteBalance = .asShot } else { whiteBalance = .custom }
    }

    /// The white balance the photo renders with.
    public func whiteBalance(asShot: WhiteBalance) -> WhiteBalance {
        WhiteBalance(temperature: temperature ?? asShot.temperature, tint: tint ?? asShot.tint)
    }
}

/// The white balance menu, in its order. The presets are Lightroom's color temperatures.
public enum WhiteBalancePreset: String, Codable, CaseIterable, Sendable {
    case asShot, auto, daylight, cloudy, shade, tungsten, fluorescent, flash, custom

    /// The preset's Kelvin; `nil` for As Shot, Auto and Custom, which have no fixed value.
    public var temperature: Double? {
        switch self {
        case .asShot, .auto, .custom: nil
        case .daylight: 5500
        case .cloudy: 6500
        case .shade: 7500
        case .tungsten: 2850
        case .fluorescent: 3800
        case .flash: 5500
        }
    }
}

/// A white balance as `CIRAWFilter` takes it: the color temperature of the light in Kelvin,
/// and a tint from green (negative) to magenta (positive).
public struct WhiteBalance: Equatable, Sendable {
    public var temperature: Double
    public var tint: Double

    public static let temperatureRange = 2000.0...50000.0
    public static let tintRange = -150.0...150.0

    public init(temperature: Double, tint: Double) {
        self.temperature = temperature
        self.tint = tint
    }

    /// The camera's white balance for the photo at `url`, or `nil` if it isn't a RAW photo.
    /// Blocks on file I/O.
    public static func asShot(of url: URL) -> WhiteBalance? {
        guard let filter = CIRAWFilter(imageURL: url), filter.nativeSize != .zero else { return nil }
        return WhiteBalance(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
    }

    /// Where `kelvin` sits on the temperature slider, from 0 to 1. The slider is spaced evenly in
    /// mireds (a million over Kelvin), which matches how much the color appears to change, so
    /// 2000–10000 K takes most of the track and 10000–50000 K the rest.
    public static func sliderPosition(forTemperature kelvin: Double) -> Double {
        let low = 1e6 / temperatureRange.lowerBound, high = 1e6 / temperatureRange.upperBound
        let mired = 1e6 / min(max(kelvin, temperatureRange.lowerBound), temperatureRange.upperBound)
        return (low - mired) / (low - high)
    }

    /// The Kelvin at `position` (0 to 1) on the temperature slider.
    public static func temperature(atSliderPosition position: Double) -> Double {
        let low = 1e6 / temperatureRange.lowerBound, high = 1e6 / temperatureRange.upperBound
        return 1e6 / (low - min(max(position, 0), 1) * (low - high))
    }
}

/// Control points per channel, each (input, output) in 0...1, sorted by input, and each
/// channel's black, midtone and white handles, which apply before its points.
public struct ToneCurve: Codable, Equatable, Sendable {
    public static let identity: [CurvePoint] = [CurvePoint(0, 0), CurvePoint(1, 1)]

    public var rgb: [CurvePoint] = ToneCurve.identity
    public var red: [CurvePoint] = ToneCurve.identity
    public var green: [CurvePoint] = ToneCurve.identity
    public var blue: [CurvePoint] = ToneCurve.identity
    public var levels = ChannelLevels()

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
        levels = try c.decodeIfPresent(ChannelLevels.self, forKey: .levels) ?? ChannelLevels()
    }
}

/// The black, midtone and white handles of each channel.
public struct ChannelLevels: Codable, Equatable, Sendable {
    public var rgb = Levels()
    public var red = Levels()
    public var green = Levels()
    public var blue = Levels()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rgb = try c.decodeIfPresent(Levels.self, forKey: .rgb) ?? Levels()
        red = try c.decodeIfPresent(Levels.self, forKey: .red) ?? Levels()
        green = try c.decodeIfPresent(Levels.self, forKey: .green) ?? Levels()
        blue = try c.decodeIfPresent(Levels.self, forKey: .blue) ?? Levels()
    }
}

/// Input levels, as in Photoshop's Levels: tones at or below `black` become black, tones at or
/// above `white` become white, and `midtone` is where middle gray lands, as a fraction of the
/// way from `black` to `white`. Encoded as a three-element array `[black, midtone, white]`.
public struct Levels: Codable, Equatable, Sendable {
    public var black: Double
    public var midtone: Double
    public var white: Double

    public init(black: Double = 0, midtone: Double = 0.5, white: Double = 1) {
        self.black = black
        self.midtone = midtone
        self.white = white
    }

    public init(from decoder: Decoder) throws {
        var c = try decoder.unkeyedContainer()
        black = try c.decode(Double.self)
        midtone = try c.decode(Double.self)
        white = try c.decode(Double.self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.unkeyedContainer()
        try c.encode(black)
        try c.encode(midtone)
        try c.encode(white)
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
