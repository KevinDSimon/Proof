import CoreImage
import Foundation
import ImageIO

/// Whose color profile turns the camera's raw colors into the photo's starting colors. Stored in
/// the recipe. `embedded` is the profile the camera maker wrote into a DNG, used only where
/// `CameraProfiles` offers it; `apple` is Core Image's own profile for the camera.
public enum CameraProfile: String, Codable, CaseIterable, Sendable {
    case embedded, apple
}

/// What the decoder gives for one photo under one profile, before anything changes it.
public struct DecoderDefaults: Equatable, Sendable {
    public var asShot: WhiteBalance
    public var detail: CameraDetail
    public var lens: CameraLens
    /// The decoded photo's size in pixels as the camera oriented it. The embedded profile's
    /// decoder uses the DNG's DefaultCropSize, which can be a few pixels larger.
    public var orientedSize: CGSize
    /// The sensor's size before orientation. Read only before any `scaleFactor` is set: the
    /// `.dng` decoders report `nativeSize` scaled by it.
    var nativeSize: CGSize

    init(of filter: CIRAWFilter) {
        asShot = WhiteBalance(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
        detail = CameraDetail(of: filter)
        lens = CameraLens(of: filter)
        nativeSize = filter.nativeSize
        orientedSize = RAWRenderer.oriented(filter.nativeSize, filter.orientation)
    }
}

/// The color profiles one photo can be decoded with, and how the inspector names them.
///
/// Core Image's default decoder uses Apple's profile for the cameras it knows, and ignores the
/// profile a DNG carries. Its `.dng` decoder versions use the DNG's color matrices, calibration
/// and baseline exposure, but ignore forward matrices, hue/sat maps and look tables, so the
/// embedded profile is offered only for a DNG whose profile has none of those (see
/// `scripts/dng-profile-diagnostic/RESULTS.md`). Where the default decoder is already a `.dng`
/// version, as for iPhone ProRAW, the embedded profile is the only one.
public struct CameraProfiles: Equatable, Sendable {
    /// The camera model as the file writes it, such as "LEICA M11" or "ILCE-7M4".
    public var model: String?
    /// The `.dng` decoder version that applies the embedded profile, when the photo offers a
    /// choice; `nil` when it has one profile.
    var embeddedDecoder: String?
    /// The default decoder already reads the file's own profile.
    var isEmbeddedOnly: Bool
    /// What the decoder gives under each profile the photo can use, keyed by `resolved` profile.
    /// Empty unless read with `readingDefaults`.
    public var defaults: [CameraProfile: DecoderDefaults] = [:]

    init(model: String?, embeddedDecoder: String?, isEmbeddedOnly: Bool) {
        self.model = model
        self.embeddedDecoder = embeddedDecoder
        self.isEmbeddedOnly = isEmbeddedOnly
    }

    /// Reads `filter` before anything changes it. With `readingDefaults`, it also reads each
    /// profile's defaults, switching the decoder and back.
    init(of filter: CIRAWFilter, readingDefaults: Bool = true) {
        let properties = filter.properties
        model = ((properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any])?[kCGImagePropertyTIFFModel as String]
            as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let dng = properties[kCGImagePropertyDNGDictionary as String] as? [String: Any]
        isEmbeddedOnly = filter.decoderVersion.rawValue.hasSuffix(".dng")
        if !isEmbeddedOnly, let dng, Self.isAppliedInFull(dng) {
            embeddedDecoder = Self.newestDNGDecoder(in: filter.supportedDecoderVersions.map(\.rawValue))
        }
        guard readingDefaults else { return }
        let original = filter.decoderVersion
        defaults[resolved(.apple)] = DecoderDefaults(of: filter)
        if let embeddedDecoder {
            filter.decoderVersion = CIRAWDecoderVersion(rawValue: embeddedDecoder)
            defaults[.embedded] = DecoderDefaults(of: filter)
            filter.decoderVersion = original
        }
    }

    /// The profiles of the photo at `url`, with each one's defaults, or `nil` if it isn't a RAW
    /// photo. Blocks on file I/O.
    public static func of(_ url: URL) -> CameraProfiles? {
        guard let filter = CIRAWFilter(imageURL: url), filter.nativeSize != .zero else { return nil }
        return CameraProfiles(of: filter)
    }

    /// Whether the inspector offers a choice between the embedded profile and Apple's.
    public var offersChoice: Bool { embeddedDecoder != nil }

    /// The profile the photo is decoded with when an edit asks for `profile`: that one where the
    /// photo offers a choice, otherwise the only one it has.
    public func resolved(_ profile: CameraProfile) -> CameraProfile {
        offersChoice ? profile : isEmbeddedOnly ? .embedded : .apple
    }

    /// The defaults under the profile `profile` resolves to.
    public func defaults(for profile: CameraProfile) -> DecoderDefaults? {
        defaults[resolved(profile)]
    }

    /// What the inspector calls `profile`. It names whose profile it is: Apple's profile for a
    /// Sony camera is "Apple · ILCE-7M4", never "Sony".
    public func label(for profile: CameraProfile) -> String {
        let camera = model ?? "Camera"
        switch resolved(profile) {
        case .embedded: return "\(camera) (embedded)"
        case .apple: return offersChoice || model == nil ? "Apple" : "Apple · \(camera)"
        }
    }

    /// Sets `filter` to decode with `profile`. `filter` must be the one these were read from.
    func select(_ profile: CameraProfile, on filter: CIRAWFilter, default original: CIRAWDecoderVersion) {
        let version = resolved(profile) == .embedded ? embeddedDecoder.map(CIRAWDecoderVersion.init(rawValue:)) : nil
        let wanted = version ?? original
        if filter.decoderVersion != wanted { filter.decoderVersion = wanted }
    }

    /// Whether Core Image's `.dng` decoder applies everything in the DNG profile `dng` describes.
    /// It ignores forward matrices, hue/sat maps and look tables that change anything.
    static func isAppliedInFull(_ dng: [String: Any]) -> Bool {
        guard dng[kCGImagePropertyDNGColorMatrix1 as String] != nil else { return false }
        let ignored = [kCGImagePropertyDNGForwardMatrix1, kCGImagePropertyDNGForwardMatrix2,
                       kCGImagePropertyDNGProfileHueSatMapData1, kCGImagePropertyDNGProfileHueSatMapData2]
        if ignored.contains(where: { dng[$0 as String] != nil }) { return false }
        guard let table = dng[kCGImagePropertyDNGProfileLookTableData as String] else { return true }
        // Each entry is a hue shift in degrees, a saturation scale and a value scale.
        guard let values = (table as? [Any])?.compactMap(Self.number), values.count % 3 == 0 else { return false }
        return stride(from: 0, to: values.count, by: 3).allSatisfy {
            values[$0] == 0 && values[$0 + 1] == 1 && values[$0 + 2] == 1
        }
    }

    /// The newest `.dng` entry of `versions`, such as "9.dng".
    static func newestDNGDecoder(in versions: [String]) -> String? {
        versions.filter { $0.hasSuffix(".dng") }
            .max { (Int($0.prefix { $0.isNumber }) ?? 0) < (Int($1.prefix { $0.isNumber }) ?? 0) }
    }

    /// The pixel size, before orientation, that the embedded profile's decoder gives the DNG
    /// `dng` describes: its DefaultCropSize. `nil` when it has none or the profile isn't applied in full.
    static func embeddedSize(_ dng: [String: Any]) -> CGSize? {
        guard isAppliedInFull(dng), let size = (dng[kCGImagePropertyDNGDefaultCropSize as String] as? [Any])?.compactMap(number),
              size.count == 2, size[0] > 0, size[1] > 0 else { return nil }
        return CGSize(width: size[0], height: size[1])
    }

    private static func number(_ value: Any) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }
}
