import CoreGraphics
import Foundation

/// How photos are exported: the file format, the size, the color space and whether the location
/// is left out. One set of settings, remembered between exports, takes the place of presets
/// (decision 0031).
public struct ExportSettings: Codable, Equatable, Sendable {
    public enum Format: String, Codable, CaseIterable, Sendable {
        case jpeg, heic, tiff

        public var title: String {
            switch self {
            case .jpeg: "JPEG"
            case .heic: "HEIC"
            case .tiff: "TIFF"
            }
        }

        public var fileExtension: String {
            switch self {
            case .jpeg: "jpg"
            case .heic: "heic"
            case .tiff: "tif"
            }
        }

        /// The uniform type identifier ImageIO writes the format by.
        public var typeIdentifier: String {
            switch self {
            case .jpeg: "public.jpeg"
            case .heic: "public.heic"
            case .tiff: "public.tiff"
            }
        }

        /// JPEG and HEIC are compressed with a quality setting. TIFF is written uncompressed at
        /// 16 bits per channel, which is what printing asks for.
        public var hasQuality: Bool { self != .tiff }
        public var bitsPerChannel: Int { self == .tiff ? 16 : 8 }
    }

    public enum Size: String, Codable, CaseIterable, Sendable {
        case original, longEdge
    }

    public enum Unit: String, Codable, CaseIterable, Sendable {
        case pixels, inches, centimeters

        public var title: String {
            switch self {
            case .pixels: "px"
            case .inches: "in"
            case .centimeters: "cm"
            }
        }

        /// Print sizes need a resolution to become pixels.
        public var isPrintSize: Bool { self != .pixels }
    }

    public enum ColorSpace: String, Codable, CaseIterable, Sendable {
        case sRGB, displayP3, adobeRGB

        public var title: String {
            switch self {
            case .sRGB: "sRGB"
            case .displayP3: "Display P3"
            case .adobeRGB: "Adobe RGB"
            }
        }

        public var cgColorSpace: CGColorSpace {
            switch self {
            case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)!
            case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)!
            case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)!
            }
        }
    }

    public var format: Format
    /// From 0 to 1, for JPEG and HEIC.
    public var quality: Double
    public var size: Size
    /// The long edge's length in `unit`, used while `size` is `longEdge`.
    public var longEdge: Double
    public var unit: Unit
    /// Pixels per inch. Turns a print size into pixels, and is written into every file so that it
    /// prints at the size it was exported for.
    public var resolution: Double
    public var colorSpace: ColorSpace
    /// Leaves out the GPS position and the location fields of the description.
    public var removesLocation: Bool

    public init(format: Format = .jpeg, quality: Double = 0.85, size: Size = .original, longEdge: Double = 2048,
                unit: Unit = .pixels, resolution: Double = 300, colorSpace: ColorSpace = .sRGB,
                removesLocation: Bool = false) {
        self.format = format
        self.quality = quality
        self.size = size
        self.longEdge = longEdge
        self.unit = unit
        self.resolution = resolution
        self.colorSpace = colorSpace
        self.removesLocation = removesLocation
    }

    /// The long edge in pixels, or `nil` for the original size. Never below 1.
    public var longEdgePixels: Int? {
        guard size == .longEdge else { return nil }
        let pixels = switch unit {
        case .pixels: longEdge
        case .inches: longEdge * resolution
        case .centimeters: longEdge / 2.54 * resolution
        }
        return max(Int(pixels.rounded()), 1)
    }

    /// The exported size of a photo whose cropped size at full resolution is `photoSize`: scaled
    /// down so its long edge is `longEdgePixels`, never up, in whole pixels.
    public func outputSize(for photoSize: CGSize) -> CGSize {
        let long = max(photoSize.width, photoSize.height)
        guard let target = longEdgePixels, long > 0, CGFloat(target) < long else { return photoSize }
        let scale = CGFloat(target) / long
        return CGSize(width: max((photoSize.width * scale).rounded(), 1), height: max((photoSize.height * scale).rounded(), 1))
    }
}
