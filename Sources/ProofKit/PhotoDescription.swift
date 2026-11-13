import Foundation
import ImageIO

/// What a person writes about a photo: its title, caption, keywords, creator, copyright and
/// location. These are the IPTC Core fields Lightroom, Capture One and Photomator show and edit,
/// stored in XMP (decision 0030). Proof saves them to the photo's sidecar, never into the photo.
///
/// An empty string means the field isn't set.
public struct PhotoDescription: Equatable, Sendable {
    public var title: String
    public var caption: String
    public var keywords: [String]
    /// `dc:creator` is a list; several names are shown joined by "; ", as Lightroom shows them.
    public var creator: String
    public var copyright: String
    public var sublocation: String
    public var city: String
    public var state: String
    public var country: String

    public static let empty = PhotoDescription()

    public init(title: String = "", caption: String = "", keywords: [String] = [], creator: String = "",
                copyright: String = "", sublocation: String = "", city: String = "", state: String = "",
                country: String = "") {
        self.title = title
        self.caption = caption
        self.keywords = keywords
        self.creator = creator
        self.copyright = copyright
        self.sublocation = sublocation
        self.city = city
        self.state = state
        self.country = country
    }

    public var isEmpty: Bool { normalized == .empty }

    /// As saved: every field trimmed, and keywords without blanks or repeats, in their order.
    public var normalized: PhotoDescription {
        var seen = Set<String>()
        func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
        return PhotoDescription(
            title: trimmed(title), caption: trimmed(caption),
            keywords: keywords.map(trimmed).filter { !$0.isEmpty && seen.insert($0).inserted },
            creator: creators.joined(separator: "; "), copyright: trimmed(copyright),
            sublocation: trimmed(sublocation), city: trimmed(city), state: trimmed(state), country: trimmed(country))
    }

    /// The names in `creator`, written as one `dc:creator` item each.
    var creators: [String] {
        creator.split(separator: ";").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Keywords as typed in one field: separated by commas, as Lightroom's Keywording panel takes them.
    public static func keywords(from text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    // MARK: Reading

    /// The description shown for `photo`: from its sidecar when it has one, which takes the place
    /// of the XMP inside the photo (decision 0005), otherwise from the photo. Blocks on file I/O.
    public static func read(for photo: URL) -> PhotoDescription {
        if let sidecar = XMPSidecar.existing(for: photo), let data = try? Data(contentsOf: sidecar),
           let description = PhotoDescription(xmp: data) {
            return description
        }
        return embedded(in: photo)
    }

    /// Reads an XMP sidecar's contents. `nil` if the data isn't XMP.
    public init?(xmp data: Data) {
        guard let metadata = CGImageMetadataCreateFromXMPData(data as CFData) else { return nil }
        self.init(metadata)
    }

    /// The description inside the photo: its XMP, then the IPTC and the camera's artist and
    /// copyright for any field the XMP leaves empty. Blocks on file I/O.
    public static func embedded(in url: URL) -> PhotoDescription {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return .empty }
        var description = CGImageSourceCopyMetadataAtIndex(source, 0, nil).map(PhotoDescription.init) ?? .empty
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            description.fillEmptyFields(from: properties)
        }
        return description
    }

    private init(_ metadata: CGImageMetadata) {
        var found = PhotoDescription()
        // Matched by namespace URI rather than prefix, since apps choose their own prefixes.
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil, nil) { _, tag in
            guard let namespace = CGImageMetadataTagCopyNamespace(tag) as String?,
                  let name = CGImageMetadataTagCopyName(tag) as String? else { return true }
            switch (namespace, name) {
            case (Self.dc, "title"): found.title = Self.text(of: tag)
            case (Self.dc, "description"): found.caption = Self.text(of: tag)
            case (Self.dc, "rights"): found.copyright = Self.text(of: tag)
            case (Self.dc, "creator"): found.creator = Self.items(of: tag).joined(separator: "; ")
            case (Self.dc, "subject"): found.keywords = Self.items(of: tag)
            case (Self.iptcCore, "Location"): found.sublocation = Self.text(of: tag)
            case (Self.photoshop, "City"): found.city = Self.text(of: tag)
            case (Self.photoshop, "State"): found.state = Self.text(of: tag)
            case (Self.photoshop, "Country"): found.country = Self.text(of: tag)
            default: break
            }
            return true
        }
        self = found.normalized
    }

    /// A simple value, or the default language of a language alternative such as `dc:title`.
    private static func text(of tag: CGImageMetadataTag) -> String {
        if let value = CGImageMetadataTagCopyValue(tag) as? String { return value }
        guard let alternatives = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] else { return "" }
        let preferred = alternatives.first { item in
            let qualifiers = CGImageMetadataTagCopyQualifiers(item) as? [CGImageMetadataTag] ?? []
            return qualifiers.contains { CGImageMetadataTagCopyName($0) as String? == "lang"
                && CGImageMetadataTagCopyValue($0) as? String == "x-default" }
        }
        return (preferred ?? alternatives.first).flatMap { CGImageMetadataTagCopyValue($0) as? String } ?? ""
    }

    /// The items of a list such as `dc:subject`, or a single value written where a list belongs.
    private static func items(of tag: CGImageMetadataTag) -> [String] {
        if let value = CGImageMetadataTagCopyValue(tag) as? String { return [value] }
        let items = CGImageMetadataTagCopyValue(tag) as? [CGImageMetadataTag] ?? []
        return items.compactMap { CGImageMetadataTagCopyValue($0) as? String }
    }

    /// IPTC written by older apps, and the artist and copyright a camera can be set to record.
    mutating func fillEmptyFields(from properties: [CFString: Any]) {
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        func string(_ value: Any?) -> String {
            if let list = value as? [String] { return list.joined(separator: "; ") }
            return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        func fill(_ field: inout String, _ values: Any?...) {
            guard field.isEmpty else { return }
            field = values.lazy.map(string).first { !$0.isEmpty } ?? ""
        }
        fill(&title, iptc[kCGImagePropertyIPTCObjectName])
        fill(&caption, iptc[kCGImagePropertyIPTCCaptionAbstract])
        fill(&creator, iptc[kCGImagePropertyIPTCByline], tiff[kCGImagePropertyTIFFArtist])
        fill(&copyright, iptc[kCGImagePropertyIPTCCopyrightNotice], tiff[kCGImagePropertyTIFFCopyright])
        fill(&sublocation, iptc[kCGImagePropertyIPTCSubLocation])
        fill(&city, iptc[kCGImagePropertyIPTCCity])
        fill(&state, iptc[kCGImagePropertyIPTCProvinceState])
        fill(&country, iptc[kCGImagePropertyIPTCCountryPrimaryLocationName])
        if keywords.isEmpty, let list = iptc[kCGImagePropertyIPTCKeywords] as? [String] { keywords = list }
        self = normalized
    }

    static let dc = "http://purl.org/dc/elements/1.1/"
    static let photoshop = "http://ns.adobe.com/photoshop/1.0/"
    static let iptcCore = "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/"
}
