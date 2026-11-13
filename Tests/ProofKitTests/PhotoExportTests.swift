import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ProofKit

struct ExportSettingsTests {
    private let m11 = CGSize(width: 9504, height: 6336)

    @Test("The original size exports every pixel")
    func originalSize() {
        #expect(ExportSettings().outputSize(for: m11) == m11)
    }

    @Test("A long edge in pixels scales the photo down to it, keeping its shape")
    func longEdgeInPixels() {
        let settings = ExportSettings(size: .longEdge, longEdge: 2048)
        #expect(settings.outputSize(for: m11) == CGSize(width: 2048, height: 1365))
        #expect(settings.outputSize(for: CGSize(width: 6336, height: 9504)) == CGSize(width: 1365, height: 2048))
    }

    @Test("A print size becomes pixels at the resolution")
    func printSize() {
        #expect(ExportSettings(size: .longEdge, longEdge: 12, unit: .inches, resolution: 300).longEdgePixels == 3600)
        #expect(ExportSettings(size: .longEdge, longEdge: 30, unit: .centimeters, resolution: 300).longEdgePixels == 3543)
    }

    @Test("A photo smaller than the long edge isn't enlarged")
    func neverEnlarges() {
        let settings = ExportSettings(size: .longEdge, longEdge: 20_000)
        #expect(settings.outputSize(for: m11) == m11)
    }

    @Test("Settings saved before a field existed still read back")
    func decodesSavedSettings() throws {
        let saved = try JSONEncoder().encode(ExportSettings(format: .tiff, colorSpace: .adobeRGB))
        #expect(try JSONDecoder().decode(ExportSettings.self, from: saved) == ExportSettings(format: .tiff, colorSpace: .adobeRGB))
    }
}

struct PhotoExportTests {
    private static func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func image(width: Int = 40, height: Int = 30) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    private static var source: [CFString: Any] { [
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyExifDictionary: [kCGImagePropertyExifExposureTime: 1.0 / 125, kCGImagePropertyExifLensModel: "Summicron"],
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: "LEICA M11", kCGImagePropertyTIFFOrientation: 6],
        kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 52.5, kCGImagePropertyGPSLatitudeRef: "N"],
        kCGImagePropertyDNGDictionary: [kCGImagePropertyDNGVersion: [1, 4, 0, 0]],
    ] }

    private static let details = PhotoExport.Details(
        rating: 4, description: PhotoDescription(title: "Pier", caption: "Evening light", keywords: ["sea"], city: "Brighton"))

    @Test("An export is named after the photo and never replaces a file")
    func destinationNames() throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let photo = URL(fileURLWithPath: "/Photos/L1000725.DNG")
        #expect(PhotoExport.destination(for: photo, format: .jpeg, in: folder).lastPathComponent == "L1000725.jpg")
        try Data().write(to: folder.appendingPathComponent("L1000725.jpg"))
        #expect(PhotoExport.destination(for: photo, format: .jpeg, in: folder).lastPathComponent == "L1000725-2.jpg")
        try Data().write(to: folder.appendingPathComponent("L1000725-2.jpg"))
        #expect(PhotoExport.destination(for: photo, format: .jpeg, in: folder).lastPathComponent == "L1000725-3.jpg")
        #expect(PhotoExport.destination(for: photo, format: .tiff, in: folder).lastPathComponent == "L1000725.tif")
    }

    @Test("Each format keeps the camera details, rating and description, upright", arguments: ExportSettings.Format.allCases)
    func roundTrip(format: ExportSettings.Format) throws {
        let folder = try Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("out").appendingPathExtension(format.fileExtension)
        let settings = ExportSettings(format: format, resolution: 240)
        let properties = PhotoExport.properties(from: Self.source, size: CGSize(width: 40, height: 30),
                                                details: Self.details, settings: settings)
        try PhotoExport.write(Self.image(), to: url, format: format, quality: 0.8, properties: properties)

        let file = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let read = try #require(CGImageSourceCopyPropertiesAtIndex(file, 0, nil) as? [CFString: Any])
        let exif = read[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifLensModel] as? String == "Summicron")
        #expect(abs((exif?[kCGImagePropertyExifExposureTime] as? Double ?? 0) - 1.0 / 125) < 1e-6)
        #expect((read[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFModel] as? String == "LEICA M11")
        #expect(read[kCGImagePropertyOrientation] as? Int ?? 1 == 1)
        #expect(read[kCGImagePropertyDPIWidth] as? Double == 240)
        #expect(read[kCGImagePropertyGPSDictionary] != nil)
        #expect(read[kCGImagePropertyDNGDictionary] == nil)
        let metadata = try #require(CGImageSourceCopyMetadataAtIndex(file, 0, nil))
        #expect(CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String? == "4")
        #expect(CGImageMetadataCopyStringValueWithPath(metadata, nil, "photoshop:City" as CFString) as String? == "Brighton")
        let xmp = try #require(CGImageMetadataCreateXMPData(metadata, nil) as Data?)
        let description = try #require(PhotoDescription(xmp: xmp))
        #expect(description.title == "Pier")
        #expect(description.caption == "Evening light")
        #expect(description.keywords == ["sea"])
    }

    @Test("Removing the location leaves out the GPS position and the description's place")
    func removesLocation() {
        let properties = PhotoExport.properties(from: Self.source, size: CGSize(width: 40, height: 30), details: Self.details,
                                                settings: ExportSettings(removesLocation: true))
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any]
        #expect(iptc?[kCGImagePropertyIPTCCity] == nil)
        #expect(iptc?[kCGImagePropertyIPTCCaptionAbstract] as? String == "Evening light")
    }

    @Test("Exif names sRGB only when the file is sRGB")
    func exifColorSpace() {
        func space(_ colorSpace: ExportSettings.ColorSpace) -> Int? {
            let properties = PhotoExport.properties(from: [:], size: CGSize(width: 1, height: 1), details: .init(),
                                                    settings: ExportSettings(colorSpace: colorSpace))
            return (properties[kCGImagePropertyExifDictionary] as? [CFString: Any])?[kCGImagePropertyExifColorSpace] as? Int
        }
        #expect(space(.sRGB) == 1)
        #expect(space(.adobeRGB) == 0xFFFF)
    }

    /// Runs only with `PROOF_SAMPLE_DNG`, like the other tests of real photos.
    @Test("An export is the exact size asked for and looks like the thumbnail", .enabled(if: sampleDNG != nil))
    func exportMatchesThumbnail() async throws {
        let url = try #require(sampleDNG)
        let renderer = try RAWRenderer()
        var recipe = EditRecipe.exposure(0.5)
        recipe.crop = Crop(x: 0.1, y: 0.1, width: 0.6, height: 0.7)
        let settings = ExportSettings(size: .longEdge, longEdge: 256, colorSpace: .displayP3)
        let exported = try await renderer.export(url, recipe: recipe, lut: nil, settings: settings)
        let thumbnail = try await renderer.thumbnail(of: url, recipe: recipe, maxPixelSize: 256)
        #expect(max(exported.width, exported.height) == 256)
        #expect(exported.alphaInfo == .noneSkipLast)
        // Both are Display P3 here, so their pixels compare directly, row for row.
        let difference = try meanDifference(exported, thumbnail)
        #expect(difference < 0.02, "mean difference \(difference)")
    }

    @Test("A TIFF export has 16 bits per channel", .enabled(if: sampleDNG != nil))
    func sixteenBitTIFF() async throws {
        let renderer = try RAWRenderer()
        let image = try await renderer.export(try #require(sampleDNG), recipe: EditRecipe(), lut: nil,
                                              settings: ExportSettings(format: .tiff, size: .longEdge, longEdge: 300))
        #expect(image.bitsPerComponent == 16)
        #expect(image.colorSpace?.name == CGColorSpace.sRGB)
    }

    /// The mean absolute difference of two images' channels, from 0 to 1, drawn at the smaller
    /// one's size so a pixel of rounding doesn't count.
    private func meanDifference(_ a: CGImage, _ b: CGImage) throws -> Double {
        let width = min(a.width, b.width), height = min(a.height, b.height)
        func pixels(_ image: CGImage) throws -> [UInt8] {
            var data = [UInt8](repeating: 0, count: width * height * 4)
            let context = try #require(CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                                                 bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return data
        }
        let (pa, pb) = (try pixels(a), try pixels(b))
        let total = zip(pa, pb).enumerated().reduce(0) { sum, item in
            item.offset % 4 == 3 ? sum : sum + abs(Int(item.element.0) - Int(item.element.1))
        }
        return Double(total) / Double(width * height * 3) / 255
    }
}
