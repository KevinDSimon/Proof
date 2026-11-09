import Foundation
import ImageIO

/// The camera settings a photo was taken with, from its EXIF, shown under the histogram. Any of
/// them can be missing: a manual lens records no aperture or focal length.
public struct CaptureSettings: Equatable, Sendable {
    public var iso: Int?
    /// In millimeters, as recorded, not the 35 mm equivalent.
    public var focalLength: Double?
    public var aperture: Double?
    /// In seconds.
    public var shutterSpeed: Double?

    public init(iso: Int? = nil, focalLength: Double? = nil, aperture: Double? = nil, shutterSpeed: Double? = nil) {
        self.iso = iso
        self.focalLength = focalLength
        self.aperture = aperture
        self.shutterSpeed = shutterSpeed
    }

    /// Reads the EXIF of the photo at `url`. `nil` if the file can't be read. Blocks on file I/O.
    public static func read(from url: URL) -> CaptureSettings? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        return CaptureSettings(exif: properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:])
    }

    init(exif: [CFString: Any]) {
        func positive(_ key: CFString) -> Double? {
            (exif[key] as? NSNumber).map(\.doubleValue).flatMap { $0 > 0 ? $0 : nil }
        }
        let isoValues = exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber]
        iso = isoValues?.first.map(\.intValue).flatMap { $0 > 0 ? $0 : nil }
        focalLength = positive(kCGImagePropertyExifFocalLength)
        aperture = positive(kCGImagePropertyExifFNumber)
        shutterSpeed = positive(kCGImagePropertyExifExposureTime)
    }

    public var isEmpty: Bool {
        iso == nil && focalLength == nil && aperture == nil && shutterSpeed == nil
    }

    public var formattedISO: String? { iso.map { "ISO \($0)" } }

    public var formattedFocalLength: String? {
        focalLength.map { "\(Self.trimmed($0, digits: 1)) mm" }
    }

    public var formattedAperture: String? {
        aperture.map { "ƒ/\(Self.trimmed($0, digits: 1))" }
    }

    /// Fractions of a second as cameras show them, `1/4000 s`; a quarter second and longer in
    /// seconds, `0.5 s` or `30 s`.
    public var formattedShutterSpeed: String? {
        guard let shutterSpeed else { return nil }
        if shutterSpeed < 0.25 {
            return "1/\(Int((1 / shutterSpeed).rounded())) s"
        }
        return "\(Self.trimmed(shutterSpeed, digits: 1)) s"
    }

    /// `1.8` stays `1.8`, `85.0` becomes `85`.
    private static func trimmed(_ value: Double, digits: Int) -> String {
        value.formatted(.number.precision(.fractionLength(0...digits)).locale(Locale(identifier: "en_US_POSIX")))
    }
}
