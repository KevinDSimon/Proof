import Foundation
import ImageIO
import Testing
@testable import ProofKit

struct PhotoInfoTests {
    static var properties: [CFString: Any] { [
        kCGImagePropertyPixelWidth: 9528,
        kCGImagePropertyPixelHeight: 6328,
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "Leica Camera AG", kCGImagePropertyTIFFModel: "LEICA M11"],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifDateTimeOriginal: "2026:11:12 14:03:27",
            kCGImagePropertyExifOffsetTimeOriginal: "+01:00",
            kCGImagePropertyExifExposureBiasValue: -0.7,
            kCGImagePropertyExifFlash: 16,
            kCGImagePropertyExifFNumber: 2.0,
            kCGImagePropertyExifLensModel: "Summicron-M 1:2/35 ASPH.",
        ] as [CFString: Any],
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 52.52, kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 13.405, kCGImagePropertyGPSLongitudeRef: "W",
        ] as [CFString: Any],
    ] }

    static let info = PhotoInfo(url: URL(fileURLWithPath: "/Volumes/Photos/2026/L1000001.DNG"), fileSize: 74_000_000,
                                properties: properties)

    @Test("The file, camera, lens and settings are read from the photo's properties")
    func reads() {
        #expect(Self.info.fileName == "L1000001.DNG")
        #expect(Self.info.folderPath == "/Volumes/Photos/2026")
        #expect(Self.info.format == "DNG")
        #expect(Self.info.camera == "LEICA M11")
        #expect(Self.info.lens == "Summicron-M 1:2/35 ASPH.")
        #expect(Self.info.settings.formattedAperture == "ƒ/2")
        #expect(Self.info.flashFired == false)
    }

    @Test("Dimensions are shown after the camera's rotation")
    func dimensions() {
        #expect(Self.info.formattedDimensions == "6328 × 9528")
    }

    @Test("The capture time keeps the offset the camera recorded")
    func captureDate() {
        #expect(Self.info.captureTimeZone == TimeZone(secondsFromGMT: 3600))
        #expect(Self.info.captureDate == Date(timeIntervalSince1970: 1_794_488_607))
    }

    @Test("Exposure compensation and GPS position read as photographers write them")
    func formatting() {
        #expect(Self.info.formattedExposureBias == "−0.7 EV")
        #expect(Self.info.formattedPosition == "52.5200° N, 13.4050° W")
    }

    @Test("The maker's name comes before a model that doesn't start with it")
    func camera() {
        #expect(PhotoInfo.camera(make: "SONY", model: "ILCE-7RM5") == "SONY ILCE-7RM5")
        #expect(PhotoInfo.camera(make: "Leica Camera AG", model: "LEICA Q3") == "LEICA Q3")
        #expect(PhotoInfo.camera(make: nil, model: nil) == nil)
    }
}
