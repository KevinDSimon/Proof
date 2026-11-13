import Foundation
import ImageIO

/// Facts about a photo's original file, shown read-only in the Info panel: the file itself, how
/// it was taken. Nothing here is written.
public struct PhotoInfo: Equatable, Sendable {
    public var fileName: String
    public var folderPath: String
    public var fileSize: Int?
    /// As shown, after the camera's orientation.
    public var pixelWidth: Int?
    public var pixelHeight: Int?
    /// The file extension, such as "DNG".
    public var format: String
    public var captureDate: Date?
    /// The offset the camera recorded with the capture time. Without one the time is shown as
    /// recorded, in GMT, so it isn't shifted into the Mac's time zone.
    public var captureTimeZone: TimeZone?
    public var camera: String?
    public var lens: String?
    public var settings: CaptureSettings
    /// In stops.
    public var exposureBias: Double?
    public var flashFired: Bool?
    public var latitude: Double?
    public var longitude: Double?

    /// Reads the photo at `url`. Fields the file doesn't have are `nil`. Blocks on file I/O.
    public static func read(from url: URL) -> PhotoInfo {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        return PhotoInfo(url: url, fileSize: size, properties: properties)
    }

    init(url: URL, fileSize: Int?, properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]

        fileName = url.lastPathComponent
        folderPath = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        self.fileSize = fileSize
        format = url.pathExtension.uppercased()

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        // Orientations 5 to 8 turn the photo a quarter turn.
        let isTurned = ((properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) >= 5
        pixelWidth = isTurned ? height : width
        pixelHeight = isTurned ? width : height

        let offset = (exif[kCGImagePropertyExifOffsetTimeOriginal] as? String).flatMap(Self.timeZone)
        captureTimeZone = offset
        captureDate = (exif[kCGImagePropertyExifDateTimeOriginal] as? String).flatMap {
            Self.date($0, in: offset ?? .gmt)
        }

        camera = Self.camera(make: tiff[kCGImagePropertyTIFFMake] as? String, model: tiff[kCGImagePropertyTIFFModel] as? String)
        lens = CameraLens.name(in: properties)
        settings = CaptureSettings(exif: exif)
        exposureBias = (exif[kCGImagePropertyExifExposureBiasValue] as? NSNumber)?.doubleValue
        // Bit 0 of the EXIF flash value says whether it fired.
        flashFired = (exif[kCGImagePropertyExifFlash] as? NSNumber).map { $0.intValue & 1 == 1 }

        func coordinate(_ value: CFString, _ reference: CFString, negative: String) -> Double? {
            guard let degrees = (gps[value] as? NSNumber)?.doubleValue else { return nil }
            return (gps[reference] as? String)?.uppercased() == negative ? -degrees : degrees
        }
        latitude = coordinate(kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef, negative: "S")
        longitude = coordinate(kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef, negative: "W")

    }

    // MARK: Formatting

    /// `9528 × 6328`.
    public var formattedDimensions: String? {
        guard let pixelWidth, let pixelHeight else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    /// `+0.7 EV`, `−1 EV`, `0 EV`.
    public var formattedExposureBias: String? {
        guard let exposureBias else { return nil }
        let number = abs(exposureBias).formatted(.number.precision(.fractionLength(0...2)).locale(Locale(identifier: "en_US_POSIX")))
        let sign = exposureBias > 0.005 ? "+" : exposureBias < -0.005 ? "−" : ""
        return "\(sign)\(number) EV"
    }

    /// `52.5200° N, 13.4050° E`.
    public var formattedPosition: String? {
        guard let latitude, let longitude else { return nil }
        func part(_ value: Double, _ positive: String, _ negative: String) -> String {
            let number = abs(value).formatted(.number.precision(.fractionLength(4)).locale(Locale(identifier: "en_US_POSIX")))
            return "\(number)° \(value < 0 ? negative : positive)"
        }
        return part(latitude, "N", "S") + ", " + part(longitude, "E", "W")
    }

    // MARK: Parsing

    /// EXIF's `2026:11:12 14:03:27`.
    static func date(_ text: String, in timeZone: TimeZone) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// EXIF's `+01:00`.
    static func timeZone(_ text: String) -> TimeZone? {
        guard let match = text.wholeMatch(of: /([+-])(\d{2}):(\d{2})/),
              let hours = Int(match.output.2), let minutes = Int(match.output.3) else { return nil }
        let seconds = (hours * 60 + minutes) * 60
        return TimeZone(secondsFromGMT: match.output.1 == "-" ? -seconds : seconds)
    }

    /// The model, after the maker's name when the model doesn't already start with it, as
    /// "LEICA M11" does and "ILCE-7RM5" doesn't.
    static func camera(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !model.isEmpty else { return make.isEmpty ? nil : make }
        guard let brand = make.split(separator: " ").first, !model.lowercased().hasPrefix(brand.lowercased()) else {
            return model
        }
        return "\(make) \(model)"
    }
}
