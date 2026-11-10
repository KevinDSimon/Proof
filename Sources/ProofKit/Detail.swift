import CoreImage
import Foundation

/// Sharpening and noise reduction, as the Detail card shows them. Each runs from 0 to 100, and
/// `nil` keeps the camera's default, which `CIRAWFilter` chooses for each photo from its camera
/// and ISO. Decision 0016 sets out which of `CIRAWFilter`'s controls these are and why.
public struct DetailAdjustments: Codable, Equatable, Sendable {
    /// How strongly edges are sharpened.
    public var sharpening: Double?
    /// How much luminance noise is smoothed away.
    public var noiseReduction: Double?
    /// How much fine detail luminance noise reduction keeps.
    public var noiseReductionDetail: Double?
    /// How much color noise is smoothed away.
    public var colorNoiseReduction: Double?

    public static let range = 0.0...100.0

    private enum CodingKeys: String, CodingKey {
        case sharpening, noiseReduction, noiseReductionDetail, colorNoiseReduction
    }

    public init(sharpening: Double? = nil, noiseReduction: Double? = nil, noiseReductionDetail: Double? = nil,
                colorNoiseReduction: Double? = nil) {
        self.sharpening = sharpening
        self.noiseReduction = noiseReduction
        self.noiseReductionDetail = noiseReductionDetail
        self.colorNoiseReduction = colorNoiseReduction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sharpening = try c.decodeIfPresent(Double.self, forKey: .sharpening)
        noiseReduction = try c.decodeIfPresent(Double.self, forKey: .noiseReduction)
        noiseReductionDetail = try c.decodeIfPresent(Double.self, forKey: .noiseReductionDetail)
        colorNoiseReduction = try c.decodeIfPresent(Double.self, forKey: .colorNoiseReduction)
    }

    /// Writes the camera's `nil` as `null`, so saving over a sidecar that had a value replaces it
    /// instead of keeping the old one (see `Sidecar`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sharpening, forKey: .sharpening)
        try c.encode(noiseReduction, forKey: .noiseReduction)
        try c.encode(noiseReductionDetail, forKey: .noiseReductionDetail)
        try c.encode(colorNoiseReduction, forKey: .colorNoiseReduction)
    }

    public var isNeutral: Bool { self == DetailAdjustments() }

    /// The values the sliders show: the edit's, and the camera's where the edit has none.
    public func shown(camera: CameraDetail) -> DetailAdjustments {
        let defaults = camera.adjustments
        return DetailAdjustments(sharpening: sharpening ?? defaults.sharpening,
                                 noiseReduction: noiseReduction ?? defaults.noiseReduction,
                                 noiseReductionDetail: noiseReductionDetail ?? defaults.noiseReductionDetail,
                                 colorNoiseReduction: colorNoiseReduction ?? defaults.colorNoiseReduction)
    }

    /// The amounts `CIRAWFilter` decodes with: the edit's, and the camera's where the edit has none.
    /// Values outside 0 to 100 decode as the nearer end.
    public func decoded(camera: CameraDetail) -> CameraDetail {
        func amount(_ value: Double?, scale: Double, camera: Double) -> Double {
            value.map { min(max($0, Self.range.lowerBound), Self.range.upperBound) / scale } ?? camera
        }
        return CameraDetail(
            sharpness: amount(sharpening, scale: CameraDetail.sharpnessScale, camera: camera.sharpness),
            luminanceNoiseReduction: amount(noiseReduction, scale: 100, camera: camera.luminanceNoiseReduction),
            detail: amount(noiseReductionDetail, scale: 100, camera: camera.detail),
            colorNoiseReduction: amount(colorNoiseReduction, scale: 100, camera: camera.colorNoiseReduction)
        )
    }
}

/// Sharpening and noise reduction as `CIRAWFilter` takes them. Read from a fresh filter, these
/// are the camera's defaults for that photo.
public struct CameraDetail: Equatable, Sendable {
    /// `sharpnessAmount`, from 0 to 2. Higher values look harsh and are left out.
    public var sharpness: Double
    /// `luminanceNoiseReductionAmount`, from 0 to 1. Above 1 the decoder makes artifacts.
    public var luminanceNoiseReduction: Double
    /// `detailAmount`, from 0 to 1.
    public var detail: Double
    /// `colorNoiseReductionAmount`, from 0 to 1.
    public var colorNoiseReduction: Double

    /// Sharpening's slider value per unit of `sharpnessAmount`: the slider's 0 to 100 covers 0 to 2,
    /// so a camera default of 1 shows as 50.
    static let sharpnessScale = 50.0

    public init(sharpness: Double, luminanceNoiseReduction: Double, detail: Double, colorNoiseReduction: Double) {
        self.sharpness = sharpness
        self.luminanceNoiseReduction = luminanceNoiseReduction
        self.detail = detail
        self.colorNoiseReduction = colorNoiseReduction
    }

    /// The defaults `filter` has before anything sets them.
    init(of filter: CIRAWFilter) {
        sharpness = Double(filter.sharpnessAmount)
        luminanceNoiseReduction = Double(filter.luminanceNoiseReductionAmount)
        detail = Double(filter.detailAmount)
        colorNoiseReduction = Double(filter.colorNoiseReductionAmount)
    }

    /// The camera's defaults for the photo at `url`, or `nil` if it isn't a RAW photo. Blocks on file I/O.
    public static func of(_ url: URL) -> CameraDetail? {
        guard let filter = CIRAWFilter(imageURL: url), filter.nativeSize != .zero else { return nil }
        return CameraDetail(of: filter)
    }

    /// These amounts as slider values, from 0 to 100.
    public var adjustments: DetailAdjustments {
        DetailAdjustments(sharpening: sharpness * Self.sharpnessScale, noiseReduction: luminanceNoiseReduction * 100,
                          noiseReductionDetail: detail * 100, colorNoiseReduction: colorNoiseReduction * 100)
    }

    /// Sets every amount on `filter`, so a filter reused across renders never keeps an earlier
    /// render's. Controls the photo's decoder doesn't support are left alone.
    func apply(to filter: CIRAWFilter) {
        if filter.isSharpnessSupported { filter.sharpnessAmount = Float(sharpness) }
        if filter.isLuminanceNoiseReductionSupported { filter.luminanceNoiseReductionAmount = Float(luminanceNoiseReduction) }
        if filter.isDetailSupported { filter.detailAmount = Float(detail) }
        if filter.isColorNoiseReductionSupported { filter.colorNoiseReductionAmount = Float(colorNoiseReduction) }
    }
}
