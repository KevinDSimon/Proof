import Foundation
import ImageIO

/// What identifies an original photo when its name changes: its size, its capture time and the
/// camera's unique image ID. A sidecar stores it so a sidecar left behind by a rename can find its
/// photo again (decision 0007).
public struct OriginalFingerprint: Codable, Equatable, Sendable {
    /// The file's size in bytes.
    public var size: Int
    /// `DateTimeOriginal` as the camera wrote it, with `SubsecTimeOriginal` after a period when
    /// present, as in `2025:06:01 14:03:22.417`. Kept as text so no time zone is assumed.
    public var captureTime: String?
    /// `RawDataUniqueID` as hexadecimal, or `ImageUniqueID` when the file has no raw data ID.
    public var uniqueID: String?

    public init(size: Int, captureTime: String? = nil, uniqueID: String? = nil) {
        self.size = size
        self.captureTime = captureTime
        self.uniqueID = uniqueID
    }

    /// Reads the fingerprint of the photo at `url`; `nil` when the file can't be found. A file
    /// ImageIO can't read gets a fingerprint of its size alone. Blocks on file I/O.
    public init?(contentsOf url: URL) {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else { return nil }
        let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        let properties = source.flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]
        self.init(size: size, properties: properties ?? [:])
    }

    init(size: Int, properties: [CFString: Any]) {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let dng = properties[kCGImagePropertyDNGDictionary] as? [CFString: Any] ?? [:]
        func text(_ value: Any?) -> String? {
            let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return string?.isEmpty == false ? string : nil
        }
        let subseconds = text(exif[kCGImagePropertyExifSubsecTimeOriginal])
        let captureTime = text(exif[kCGImagePropertyExifDateTimeOriginal]).map { time in
            subseconds.map { time + "." + $0 } ?? time
        }
        self.init(size: size, captureTime: captureTime,
                  uniqueID: Self.hex(dng[kCGImagePropertyDNGRawDataUniqueID]) ?? text(exif[kCGImagePropertyExifImageUniqueID]))
    }

    /// ImageIO gives `RawDataUniqueID`, 16 bytes, as data or as an array of numbers.
    private static func hex(_ value: Any?) -> String? {
        let bytes: [UInt8]
        if let data = value as? Data {
            bytes = Array(data)
        } else if let numbers = value as? [NSNumber] {
            bytes = numbers.map(\.uint8Value)
        } else {
            return nil
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
