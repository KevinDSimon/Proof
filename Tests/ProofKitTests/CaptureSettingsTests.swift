import Foundation
import ImageIO
import Testing
@testable import ProofKit

struct CaptureSettingsTests {
    @Test("Settings are read from EXIF and shown the way cameras show them")
    func formatsSettings() {
        let settings = CaptureSettings(exif: [
            kCGImagePropertyExifISOSpeedRatings: [160],
            kCGImagePropertyExifFocalLength: 85.0,
            kCGImagePropertyExifFNumber: 1.8,
            kCGImagePropertyExifExposureTime: 0.00025,
        ])
        #expect(settings.formattedISO == "ISO 160")
        #expect(settings.formattedFocalLength == "85 mm")
        #expect(settings.formattedAperture == "ƒ/1.8")
        #expect(settings.formattedShutterSpeed == "1/4000 s")
    }

    @Test("Shutter speeds of a quarter second and longer are shown in seconds")
    func longExposures() {
        #expect(CaptureSettings(shutterSpeed: 1.0 / 60).formattedShutterSpeed == "1/60 s")
        #expect(CaptureSettings(shutterSpeed: 0.5).formattedShutterSpeed == "0.5 s")
        #expect(CaptureSettings(shutterSpeed: 30).formattedShutterSpeed == "30 s")
    }

    @Test("Missing or zero values, as a manual lens records, are left out")
    func missingValues() {
        let settings = CaptureSettings(exif: [kCGImagePropertyExifFNumber: 0, kCGImagePropertyExifISOSpeedRatings: [400]])
        #expect(settings.aperture == nil)
        #expect(settings.focalLength == nil)
        #expect(settings.iso == 400)
        #expect(CaptureSettings(exif: [:]).isEmpty)
    }

    @Test("A real RAW photo's settings are read", .enabled(if: sampleDNG != nil))
    func readsSample() throws {
        let url = try #require(sampleDNG)
        let settings = try #require(CaptureSettings.read(from: url))
        #expect(settings.iso != nil)
        #expect(settings.shutterSpeed != nil)
    }
}
