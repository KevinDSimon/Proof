import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct RAWRendererTests {
    private let m11 = CGSize(width: 9504, height: 6320)

    @Test("A landscape photo is scaled down to fit the window")
    func fitsLandscape() {
        let scale = RAWRenderer.scaleFactor(nativeSize: m11, orientation: .up, fitting: CGSize(width: 1900, height: 2000))
        #expect(abs(scale - 0.2) < 0.0001)
    }

    @Test("A portrait photo fits by its rotated size")
    func fitsPortrait() {
        let scale = RAWRenderer.scaleFactor(nativeSize: m11, orientation: .right, fitting: CGSize(width: 2000, height: 1900.8))
        #expect(abs(scale - 0.2) < 0.0001)
    }

    @Test("A photo is never rendered larger than the sensor")
    func neverUpscales() {
        let scale = RAWRenderer.scaleFactor(nativeSize: m11, orientation: .up, fitting: CGSize(width: 20_000, height: 20_000))
        #expect(scale == 1)
    }

    @Test("Opening a file that isn't a RAW photo fails")
    func rejectsNonRAW() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-photo.dng")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let renderer = try RAWRenderer()
        await #expect(throws: RAWRendererError.unsupportedFile(url)) {
            try await renderer.open(url)
        }
    }

    @Test("Rendering before opening a photo fails")
    func requiresOpenPhoto() async throws {
        let renderer = try RAWRenderer()
        await #expect(throws: RAWRendererError.noPhotoOpen) {
            _ = try await renderer.render(fitting: CGSize(width: 100, height: 100))
        }
    }

    /// RAW files can't be committed, so this runs only when `PROOF_SAMPLE_DNG` names one, e.g.
    /// `PROOF_SAMPLE_DNG=~/Pictures/L1000725.DNG swift test`. Set `PROOF_RENDER_OUTPUT` to a
    /// .png path to also save the render for a visual check.
    @Test("A real RAW photo renders at the requested size", .enabled(if: sampleDNG != nil))
    func rendersSample() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let target = CGSize(width: 1600, height: 1000)
        let photo = try await renderer.render(fitting: target)

        let size = CGSize(width: photo.texture.width, height: photo.texture.height)
        #expect(size.width <= target.width + 1 && size.height <= target.height + 1)
        #expect(size.width >= target.width - 1 || size.height >= target.height - 1)

        if let output = ProcessInfo.processInfo.environment["PROOF_RENDER_OUTPUT"] {
            let image = try #require(CIImage(mtlTexture: photo.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
            try CIContext().writePNGRepresentation(of: image, to: URL(fileURLWithPath: output),
                                                   format: .RGBA8, colorSpace: RAWRenderer.colorSpace)
        }
    }
}

private let sampleDNG = ProcessInfo.processInfo.environment["PROOF_SAMPLE_DNG"].map(URL.init(fileURLWithPath:))
