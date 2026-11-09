import Foundation
import ImageIO

/// A photo's star rating, flag and color label as other apps record them in XMP. Proof reads these
/// and never writes them.
///
/// Apps disagree on the details, so reading is lenient:
/// - Stars are `xmp:Rating`. Bridge and darktable write -1 for a rejected photo; some apps write
///   a decimal such as `3.0`. A value outside -1 to 5 counts as no stars.
/// - The flag is `xmpDM:pick` (1 flagged, 0 unflagged, -1 rejected), which Lightroom writes from
///   Lightroom Classic 13.2 on, or `xmpDM:good` when `pick` is missing.
/// - The label is `xmp:Label`, kept as written. Lightroom lets people rename and translate labels,
///   so only the color names in `Color` are recognized as colors.
public struct PhotoMetadata: Equatable, Sendable {
    public enum Flag: String, Equatable, Sendable {
        case unflagged, flagged, rejected
    }

    /// The label colors that Lightroom, Bridge, Photomator and Capture One write by English name.
    /// Orange and pink come from Capture One.
    public enum Color: String, CaseIterable, Equatable, Sendable {
        case red, orange, yellow, green, blue, pink, purple
    }

    /// Stars from 0 to 5.
    public var rating: Int
    public var flag: Flag
    public var label: String?

    public static let unrated = PhotoMetadata()

    public init(rating: Int = 0, flag: Flag = .unflagged, label: String? = nil) {
        self.rating = rating
        self.flag = flag
        self.label = label
    }

    /// The label's color, if the label is a standard color name in any capitalization.
    public var color: Color? {
        label.flatMap { Color(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) }
    }

    /// Reads an XMP sidecar's contents. `nil` if the data isn't XMP.
    public init?(xmp data: Data) {
        guard let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        self.init(metadata)
    }

    /// Reads the XMP embedded in a photo, such as the block Lightroom writes into a DNG.
    /// `nil` if the file can't be read or has no metadata. Blocks on file I/O.
    public static func embedded(in url: URL) -> PhotoMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        else { return nil }
        return PhotoMetadata(metadata)
    }

    private init(_ metadata: CGImageMetadata) {
        // Tags are matched by namespace URI rather than prefix: apps choose their own prefixes,
        // and ImageIO has no registered prefix for xmpDM.
        var values: [String: String] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            if let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
               let name = CGImageMetadataTagCopyName(tag) as String?,
               let value = CGImageMetadataTagCopyValue(tag) as? String {
                values[namespace + name] = value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return true
        }

        let stars = values[Self.xmp + "Rating"].flatMap(Double.init).map { Int($0.rounded()) }
        rating = stars.flatMap { (0...5).contains($0) ? $0 : nil } ?? 0

        let pick = values[Self.xmpDM + "pick"].flatMap(Double.init).map { Int($0.rounded()) }
        let good = values[Self.xmpDM + "good"]?.lowercased()
        flag = switch (pick, good) {
        case (1, _): .flagged
        case (-1, _): .rejected
        case (nil, "true"): .flagged
        case (nil, "false"): .rejected
        default: .unflagged
        }
        if stars == -1 { flag = .rejected }

        label = values[Self.xmp + "Label"].flatMap { $0.isEmpty ? nil : $0 }
    }

    private static let xmp = "http://ns.adobe.com/xap/1.0/"
    private static let xmpDM = "http://ns.adobe.com/xmp/1.0/DynamicMedia/"

    /// The sidecar names apps use for `photoName`, such as `IMG_1.xmp` (Lightroom, Photomator,
    /// Capture One) and `IMG_1.DNG.xmp` (darktable, digiKam), lowercased for matching on disks
    /// that may or may not ignore case.
    static func sidecarKeys(for photoName: String) -> [String] {
        let base = (photoName as NSString).deletingPathExtension
        return [base + ".xmp", photoName + ".xmp"].map { $0.lowercased() }
    }
}
