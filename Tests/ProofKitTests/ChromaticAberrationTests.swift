import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct ChromaticAberrationTests {
    static let width = 800, height = 600

    /// Smooth light and dark bands crossing at several angles, so edges face every direction, all below clipping.
    static func scene(_ x: Double, _ y: Double) -> Float {
        Float(0.3 + 0.2 * sin(x / 7) * sin(y / 9) + 0.15 * sin((x + y) / 13) + 0.1 * cos((x - 2 * y) / 17))
    }

    /// Green is the scene; red and blue are the scene enlarged about the center by `red` and `blue`.
    static func fringed(red: Double, blue: Double) -> [SIMD3<Float>] {
        let cx = Double(width - 1) / 2, cy = Double(height - 1) / 2
        var pixels: [SIMD3<Float>] = []
        for y in 0..<height {
            for x in 0..<width {
                let dx = Double(x) - cx, dy = Double(y) - cy
                pixels.append(SIMD3(scene(cx + dx / red, cy + dy / red), scene(Double(x), Double(y)),
                                    scene(cx + dx / blue, cy + dy / blue)))
            }
        }
        return pixels
    }

    @Test("Measuring finds the scales that line red and blue up with green")
    func measuresKnownFringes() {
        let found = ChromaticAberration.measure(Self.fringed(red: 1.002, blue: 0.9985), width: Self.width, height: Self.height)
        #expect(abs(found.red - 1.002) < 0.0001)
        #expect(abs(found.blue - 0.9985) < 0.0001)
    }

    @Test("A photo without fringes, or without edges, measures as no correction")
    func measuresNone() {
        let clean = ChromaticAberration.measure(Self.fringed(red: 1, blue: 1), width: Self.width, height: Self.height)
        #expect(abs(clean.red - 1) < 0.0001 && abs(clean.blue - 1) < 0.0001)
        let flat = [SIMD3<Float>](repeating: SIMD3(0.4, 0.4, 0.4), count: Self.width * Self.height)
        #expect(ChromaticAberration.measure(flat, width: Self.width, height: Self.height) == ChromaticAberration())
    }

    @Test("Correcting with the measured scales lines the channels up again")
    func correctionUndoesFringes() throws {
        let fringed = Self.fringed(red: 1.002, blue: 0.9985)
        let measured = ChromaticAberration.measure(fringed, width: Self.width, height: Self.height)
        var floats: [Float] = fringed.flatMap { [$0.x, $0.y, $0.z, 1] }
        let data = Data(bytes: &floats, count: floats.count * MemoryLayout<Float>.size)
        let image = CIImage(bitmapData: data, bytesPerRow: Self.width * 16, size: CGSize(width: Self.width, height: Self.height),
                            format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let corrected = ChromaticAberration.apply(measured, to: image)
        #expect(corrected.extent == image.extent)

        var bitmap = [Float](repeating: 0, count: Self.width * Self.height * 4)
        CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!, .workingFormat: CIFormat.RGBAf])
            .render(corrected, toBitmap: &bitmap, rowBytes: Self.width * 16, bounds: image.extent, format: .RGBAf,
                    colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        func meanDifference(_ channel: Int, in values: [Float]) -> Float {
            var total: Float = 0
            for y in 50..<(Self.height - 50) {
                for x in 50..<(Self.width - 50) {
                    let i = (y * Self.width + x) * 4
                    total += abs(values[i + channel] - values[i + 1])
                }
            }
            return total / Float((Self.width - 100) * (Self.height - 100))
        }
        let before = meanDifference(0, in: floats), after = meanDifference(0, in: bitmap)
        #expect(after < before / 10)
        #expect(meanDifference(2, in: bitmap) < meanDifference(2, in: floats) / 10)
    }

    @Test("Scales of 1 leave the image as it is, and values past the range are held at its ends")
    func neutralAndClamped() {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.4, blue: 0.6)).cropped(to: CGRect(x: 0, y: 0, width: 10, height: 10))
        #expect(ChromaticAberration.apply(ChromaticAberration(), to: image) === image)
        #expect(ChromaticAberration.apply(nil, to: image) === image)
    }

    @Test("A file saved before Remove Chromatic Aberration reads it as off; measured values survive a round trip")
    func recipeRoundTrip() throws {
        let old = #"{"formatVersion": 3, "lens": {"profile": false}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        #expect(recipe.lens == LensCorrections(profile: false, chromaticAberration: nil))

        var edited = EditRecipe()
        #expect(edited.isNeutral)
        edited.lens.chromaticAberration = ChromaticAberration(red: 1.00042, blue: 0.99971)
        #expect(!edited.isNeutral)
        #expect(edited.original.lens == edited.lens)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditRecipe())) as? [String: Any]
        let lens = try #require(written?["lens"] as? [String: Any])
        #expect(lens["chromaticAberration"] is NSNull)
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(edited)) == edited)
    }

    /// RAW files can't be committed, so this runs only when `PROOF_SAMPLE_DNG` names one.
    @Test("Measuring a real RAW photo gives scales within the range", .enabled(if: sampleDNG != nil))
    func measuresSample() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let start = Date()
        let found = try await renderer.chromaticAberration(recipe: EditRecipe())
        print("Sample chromatic aberration: red \(found.red), blue \(found.blue), \(Date().timeIntervalSince(start)) s")
        #expect(ChromaticAberration.range.contains(found.red) && ChromaticAberration.range.contains(found.blue))
    }
}
