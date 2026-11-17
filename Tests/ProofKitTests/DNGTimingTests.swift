import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import ProofKit

/// Times the three ways Proof reads a DNG, for issue #4. Runs only when `PROOF_SAMPLE_DNG` names
/// a file, so the same test measures local disk and a network share by pointing it at each copy:
/// `PROOF_SAMPLE_DNG=/Volumes/photo/L1000725.DNG swift test --filter DNGTimingTests`.
///
/// The first read of each kind is reported on its own because it is the only one that can miss
/// the operating system's file cache. Unmount and remount a share, or copy a fresh file, before a
/// run to measure a cold read.
@Suite(.serialized, .enabled(if: timingDNG != nil))
struct DNGTimingTests {
    /// A filmstrip thumbnail, a window-sized preview, a Retina full-screen preview and the whole
    /// embedded image. Each read opens the file again.
    @Test("Embedded preview read timings")
    func previewTimings() throws {
        let url = try #require(timingDNG)
        for maxPixelSize in [512, 1600, 2880, nil] {
            var size = ""
            let times = try (0..<7).map { _ in
                let start = ContinuousClock.now
                let image = try #require(Self.embeddedPreview(url, maxPixelSize: maxPixelSize))
                let ms = (ContinuousClock.now - start) / .milliseconds(1)
                size = "\(image.width)×\(image.height)"
                return ms
            }
            report("Embedded preview (\(size))", times)
        }
    }

    /// An exposure change on an open photo at the sizes a slider drag could use. Each size is
    /// warmed up once, so these exclude the file read.
    @Test("Proxy render timings")
    func proxyTimings() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(timingDNG))
        for scale in [0.25, 0.125] {
            _ = try await renderer.render(scaleFactor: scale, recipe: EditRecipe())
            var size = ""
            var times: [Double] = []
            for exposure in [0.5, -0.5, 1, -1, 1.5, -1.5, 2] {
                let start = ContinuousClock.now
                let photo = try await renderer.render(scaleFactor: scale, recipe: .exposure(exposure))
                times.append((ContinuousClock.now - start) / .milliseconds(1))
                size = "\(photo.texture.width)×\(photo.texture.height)"
            }
            report("Proxy render, scaleFactor \(scale) (\(size))", times)
        }
    }

    /// Opening the file and rendering it at full sensor resolution, as export will. Each run uses
    /// a new renderer so the file is read again.
    @Test("Full render timings, from opening the file")
    func fullTimings() async throws {
        let url = try #require(timingDNG)
        var opens: [Double] = []
        var totals: [Double] = []
        var size = ""
        for _ in 0..<3 {
            let renderer = try RAWRenderer()
            let start = ContinuousClock.now
            try await renderer.open(url)
            opens.append((ContinuousClock.now - start) / .milliseconds(1))
            let photo = try await renderer.render(scaleFactor: 1, recipe: EditRecipe())
            totals.append((ContinuousClock.now - start) / .milliseconds(1))
            size = "\(photo.texture.width)×\(photo.texture.height)"
        }
        report("Open", opens)
        report("Open and full render (\(size))", totals)
    }

    /// A full-size export, for issue #196: the render, reading the original's metadata, and
    /// encoding the file, each timed on its own. Each run uses a new renderer, as an export does.
    @Test("Export timings")
    func exportTimings() async throws {
        let url = try #require(timingDNG)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for format in [ExportSettings.Format.jpeg, .tiff] {
            let settings = ExportSettings(format: format)
            var renders: [Double] = [], encodes: [Double] = [], totals: [Double] = []
            var size = ""
            for _ in 0..<3 {
                let renderer = try RAWRenderer()
                let start = ContinuousClock.now
                let image = try await renderer.export(url, recipe: EditRecipe(), settings: settings)
                let rendered = ContinuousClock.now
                try PhotoExport.write(image, to: PhotoExport.destination(for: url, format: format, in: folder),
                                      format: format, quality: settings.quality, properties: [:])
                let end = ContinuousClock.now
                renders.append((rendered - start) / .milliseconds(1))
                encodes.append((end - rendered) / .milliseconds(1))
                totals.append((end - start) / .milliseconds(1))
                size = "\(image.width)×\(image.height)"
            }
            report("\(format.title) export render (\(size))", renders)
            report("\(format.title) export encode and write", encodes)
            report("\(format.title) export total", totals)
        }
    }

    /// The preview the camera embedded in the file, decoded no larger than `maxPixelSize` on its
    /// long side. A smaller size is much faster because the JPEG decoder skips detail it would
    /// discard. Never decodes the RAW data: if the file has no preview this returns nil.
    static func embeddedPreview(_ url: URL, maxPixelSize: Int?) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if let maxPixelSize { options[kCGImageSourceThumbnailMaxPixelSize] = maxPixelSize }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func report(_ label: String, _ times: [Double]) {
        let rest = times.dropFirst().sorted()
        let median = rest.isEmpty ? times[0] : rest[rest.count / 2]
        print("\(label): first \(Self.ms(times[0])), then median \(Self.ms(median)) over \(rest.count) "
            + "(range \(Self.ms(rest.first ?? times[0]))–\(Self.ms(rest.last ?? times[0])))")
    }

    private static func ms(_ value: Double) -> String { String(format: "%.1f ms", value) }
}

private let timingDNG = ProcessInfo.processInfo.environment["PROOF_SAMPLE_DNG"].map(URL.init(fileURLWithPath:))
