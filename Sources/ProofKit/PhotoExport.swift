import CoreGraphics
import Foundation
import ImageIO

public enum PhotoExportError: Error, LocalizedError, Equatable {
    case couldNotWrite(URL)

    public var errorDescription: String? {
        switch self {
        case .couldNotWrite(let url): "“\(url.lastPathComponent)” couldn't be written."
        }
    }
}

/// Writes a rendered photo to a JPEG, HEIC or TIFF file next to the photo's camera details, rating
/// and description (decision 0031). The original is only read.
public enum PhotoExport {
    /// What an export carries over from the photo besides its pixels.
    public struct Details: Sendable {
        public var rating: Int
        public var description: PhotoDescription

        public init(rating: Int = 0, description: PhotoDescription = .empty) {
            self.rating = rating
            self.description = description
        }
    }

    /// Renders `photo` with `recipe` as `settings` describe and writes it into `folder`, named
    /// after the photo and never over an existing file. `renderer` should be one used only for
    /// exports, so a full-resolution render never holds up the canvas. Returns the file written.
    /// Blocks on file I/O.
    public static func export(_ photo: URL, recipe: EditRecipe, lut: PreparedLUT?, details: Details,
                              settings: ExportSettings, into folder: URL, with renderer: RAWRenderer) async throws -> URL {
        let image = try await renderer.export(photo, recipe: recipe, lut: lut, settings: settings)
        let source = CGImageSourceCreateWithURL(photo as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
            .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] } ?? [:]
        let properties = properties(from: source, size: CGSize(width: image.width, height: image.height),
                                    details: details, settings: settings)
        let destination = destination(for: photo, format: settings.format, in: folder)
        try write(image, to: destination, format: settings.format, quality: settings.quality, properties: properties)
        return destination
    }

    /// `folder`'s file for `photo` in `format`: the photo's name with the format's extension, and
    /// "-2", "-3" and so on before it while a file of that name exists.
    public static func destination(for photo: URL, format: ExportSettings.Format, in folder: URL) -> URL {
        let name = photo.deletingPathExtension().lastPathComponent
        var candidate = folder.appendingPathComponent(name).appendingPathExtension(format.fileExtension)
        var number = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(name)-\(number)").appendingPathExtension(format.fileExtension)
            number += 1
        }
        return candidate
    }

    /// The ImageIO properties for an exported file of `size`: the original's Exif, Exif aux, TIFF
    /// and GPS dictionaries, adjusted to the new pixels, and IPTC built from `details`, which
    /// ImageIO also writes as XMP. Everything else in the original, such as its DNG tags and
    /// maker notes, is left out.
    static func properties(from source: [CFString: Any], size: CGSize, details: Details,
                           settings: ExportSettings) -> [CFString: Any] {
        var properties: [CFString: Any] = [
            // The pixels are already turned upright.
            kCGImagePropertyOrientation: 1,
            kCGImagePropertyDPIWidth: settings.resolution,
            kCGImagePropertyDPIHeight: settings.resolution,
        ]
        if settings.format.hasQuality {
            properties[kCGImageDestinationLossyCompressionQuality] = settings.quality
        }

        var exif = source[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifPixelXDimension] = Int(size.width)
        exif[kCGImagePropertyExifPixelYDimension] = Int(size.height)
        // Exif can only name sRGB; any other space is "uncalibrated" and the embedded profile says which.
        exif[kCGImagePropertyExifColorSpace] = settings.colorSpace == .sRGB ? 1 : 0xFFFF
        exif[kCGImagePropertyExifMakerNote] = nil
        properties[kCGImagePropertyExifDictionary] = exif

        if let aux = source[kCGImagePropertyExifAuxDictionary] { properties[kCGImagePropertyExifAuxDictionary] = aux }

        var tiff = source[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        tiff[kCGImagePropertyTIFFOrientation] = 1
        tiff[kCGImagePropertyTIFFXResolution] = settings.resolution
        tiff[kCGImagePropertyTIFFYResolution] = settings.resolution
        tiff[kCGImagePropertyTIFFResolutionUnit] = 2  // inches
        properties[kCGImagePropertyTIFFDictionary] = tiff

        if !settings.removesLocation, let gps = source[kCGImagePropertyGPSDictionary] {
            properties[kCGImagePropertyGPSDictionary] = gps
        }

        let description = details.description.normalized
        var iptc: [CFString: Any] = [:]
        func set(_ key: CFString, _ value: String) { if !value.isEmpty { iptc[key] = value } }
        if details.rating > 0 { iptc[kCGImagePropertyIPTCStarRating] = details.rating }
        set(kCGImagePropertyIPTCObjectName, description.title)
        set(kCGImagePropertyIPTCCaptionAbstract, description.caption)
        if !description.keywords.isEmpty { iptc[kCGImagePropertyIPTCKeywords] = description.keywords }
        if !description.creators.isEmpty { iptc[kCGImagePropertyIPTCByline] = description.creators }
        set(kCGImagePropertyIPTCCopyrightNotice, description.copyright)
        if !settings.removesLocation {
            set(kCGImagePropertyIPTCSubLocation, description.sublocation)
            set(kCGImagePropertyIPTCCity, description.city)
            set(kCGImagePropertyIPTCProvinceState, description.state)
            set(kCGImagePropertyIPTCCountryPrimaryLocationName, description.country)
        }
        if !iptc.isEmpty { properties[kCGImagePropertyIPTCDictionary] = iptc }
        return properties
    }

    /// Writes `image` with `properties`. A file left half written is removed.
    static func write(_ image: CGImage, to url: URL, format: ExportSettings.Format, quality: Double,
                      properties: [CFString: Any]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, format.typeIdentifier as CFString, 1, nil) else {
            throw PhotoExportError.couldNotWrite(url)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw PhotoExportError.couldNotWrite(url)
        }
    }
}
