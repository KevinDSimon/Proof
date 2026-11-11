import CoreImage
import Foundation
import ImageIO

/// Lens corrections: the profile, the distortion and vignetting correction that `CIRAWFilter`
/// reads from the RAW file where the camera or Apple provides one, and chromatic aberration,
/// which Proof measures itself.
public struct LensCorrections: Codable, Equatable, Sendable {
    /// Whether the profile applies. `nil` keeps the decoder's default for the photo, which is how
    /// every edit rendered before this setting existed.
    public var profile: Bool?
    /// Measured when Remove Chromatic Aberration is turned on; `nil` while it is off. The values
    /// are kept, not measured again, so the photo renders the same in a later version.
    public var chromaticAberration: ChromaticAberration?

    public init(profile: Bool? = nil, chromaticAberration: ChromaticAberration? = nil) {
        self.profile = profile
        self.chromaticAberration = chromaticAberration
    }

    private enum CodingKeys: String, CodingKey { case profile, chromaticAberration }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        profile = try c.decodeIfPresent(Bool.self, forKey: .profile)
        chromaticAberration = try c.decodeIfPresent(ChromaticAberration.self, forKey: .chromaticAberration)
    }

    /// Writes the decoder's default and no chromatic aberration as `null`, so saving over a sidecar
    /// that had a value replaces it instead of keeping the old one (see `Sidecar`).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(profile, forKey: .profile)
        try c.encode(chromaticAberration, forKey: .chromaticAberration)
    }

    public var isNeutral: Bool { profile == nil && chromaticAberration == nil }

    /// Whether the profile applies to a photo taken with `lens`. Never for a photo without one.
    public func appliesProfile(for lens: CameraLens) -> Bool {
        lens.hasProfile && (profile ?? lens.profileIsOnByDefault)
    }
}

/// The lens a photo was taken with, and whether its RAW file carries a correction profile that
/// `CIRAWFilter` can apply.
public struct CameraLens: Equatable, Sendable {
    /// The lens's name as the camera recorded it, `nil` when it recorded none, as with an
    /// uncoded or adapted lens.
    public var name: String?
    public var hasProfile: Bool
    /// The decoder's default for the profile, which an edit without its own setting keeps.
    public var profileIsOnByDefault: Bool

    public init(name: String? = nil, hasProfile: Bool = false, profileIsOnByDefault: Bool = false) {
        self.name = name
        self.hasProfile = hasProfile
        self.profileIsOnByDefault = profileIsOnByDefault
    }

    /// What `filter` offers before anything changes it. The name isn't read.
    init(of filter: CIRAWFilter) {
        name = nil
        hasProfile = filter.isLensCorrectionSupported
        profileIsOnByDefault = filter.isLensCorrectionSupported && filter.isLensCorrectionEnabled
    }

    /// The lens of the photo at `url`, or `nil` if it isn't a RAW photo. Blocks on file I/O.
    public static func of(_ url: URL) -> CameraLens? {
        guard let filter = CIRAWFilter(imageURL: url), filter.nativeSize != .zero else { return nil }
        var lens = CameraLens(of: filter)
        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            lens.name = name(in: properties)
        }
        return lens
    }

    /// The EXIF lens model, or the older auxiliary one some cameras write instead.
    static func name(in properties: [CFString: Any]) -> String? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let aux = properties[kCGImagePropertyExifAuxDictionary] as? [CFString: Any]
        for value in [exif?[kCGImagePropertyExifLensModel], aux?[kCGImagePropertyExifAuxLensModel]] {
            if let name = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                return name
            }
        }
        return nil
    }
}
