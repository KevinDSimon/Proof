import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct DetailTests {
    /// Defaults as the sample photo's decoder gives them: sharpening 1, no luminance noise
    /// reduction, color noise reduction 0.5.
    static let camera = CameraDetail(sharpness: 1, luminanceNoiseReduction: 0, detail: 0, colorNoiseReduction: 0.5)

    @Test("A format 3 file saved before the Detail card keeps the camera's sharpening and noise reduction")
    func migratesRecipeWithoutDetail() throws {
        let json = #"{"formatVersion": 3, "processVersion": 1, "basic": {"exposure": 0.5}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(json.utf8))
        #expect(recipe.detail == DetailAdjustments())
        #expect(recipe.detail.decoded(camera: Self.camera) == Self.camera)
        #expect(recipe.processVersion == 1 && recipe.formatVersion == 3)
        let partial = #"{"detail": {"sharpening": 70}}"#
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: Data(partial.utf8))
        #expect(decoded.detail == DetailAdjustments(sharpening: 70))
    }

    @Test("Detail survives a JSON round trip, and the camera's values are written as null")
    func roundTrip() throws {
        var recipe = EditRecipe()
        recipe.detail = DetailAdjustments(sharpening: 80, noiseReduction: 30, noiseReductionDetail: 60)
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded == recipe)

        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(EditRecipe())) as? [String: Any]
        let detail = object?["detail"] as? [String: Any]
        #expect(detail?.count == 4)
        #expect(detail?.values.allSatisfy { $0 is NSNull } == true)
    }

    @Test("Any detail value makes the recipe not neutral, even one equal to the camera's")
    func neutrality() {
        var recipe = EditRecipe()
        recipe.detail.colorNoiseReduction = 50
        #expect(!recipe.isNeutral)
        recipe.detail.colorNoiseReduction = nil
        #expect(recipe.isNeutral)
    }

    @Test("The sliders show the camera's defaults where the edit has none")
    func shownValues() {
        let shown = DetailAdjustments(noiseReduction: 40).shown(camera: Self.camera)
        #expect(shown == DetailAdjustments(sharpening: 50, noiseReduction: 40, noiseReductionDetail: 0, colorNoiseReduction: 50))
    }

    @Test("Slider values map to the decoder's amounts, clamped to 0 to 100")
    func decodedAmounts() {
        let detail = DetailAdjustments(sharpening: 100, noiseReduction: 150, noiseReductionDetail: 25, colorNoiseReduction: -10)
        #expect(detail.decoded(camera: Self.camera)
            == CameraDetail(sharpness: 2, luminanceNoiseReduction: 1, detail: 0.25, colorNoiseReduction: 0))
        // The camera's own values round-trip through the sliders.
        #expect(Self.camera.adjustments.decoded(camera: CameraDetail(sharpness: 0, luminanceNoiseReduction: 0, detail: 0,
                                                                     colorNoiseReduction: 0)) == Self.camera)
    }

    /// The renderer reuses one filter, so after a detail change the camera's defaults have to be
    /// put back rather than the last values kept. Rendered at 100%, where sharpening applies.
    @Test("Returning to the camera's detail renders the same pixels as a fresh renderer", .enabled(if: sampleDNG != nil))
    func cameraDetailAfterChangeMatchesFresh() async throws {
        let url = try #require(sampleDNG)
        let region = CGRect(x: 0.45, y: 0.45, width: 0.04, height: 0.06)
        let fresh = try RAWRenderer()
        try await fresh.open(url)
        let expected = try pixels(await fresh.render(region: region, scale: 1))

        let reused = try RAWRenderer()
        try await reused.open(url)
        var changed = EditRecipe()
        changed.detail = DetailAdjustments(sharpening: 100, noiseReduction: 100, noiseReductionDetail: 100, colorNoiseReduction: 0)
        _ = try await reused.render(region: region, scale: 1, recipe: changed)
        let actual = try pixels(await reused.render(region: region, scale: 1))
        #expect(actual == expected)
    }

    @Test("More sharpening raises fine contrast at 100%, and none lowers it", .enabled(if: sampleDNG != nil))
    func sharpeningSharpens() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let region = CGRect(x: 0.45, y: 0.45, width: 0.04, height: 0.06)
        func edges(_ sharpening: Double?) async throws -> Double {
            var recipe = EditRecipe()
            recipe.detail.sharpening = sharpening
            return try edgeEnergy(await renderer.render(region: region, scale: 1, recipe: recipe))
        }
        let camera = try await edges(nil), none = try await edges(0), most = try await edges(100)
        #expect(none < camera * 0.8)
        #expect(most > camera * 1.5)
    }

    /// Records how long a detail slider change takes on the 60 MP sample: at a full-screen fit,
    /// where the decoder doesn't sharpen, and on a Retina window's region at 100%, where it does.
    /// Every change repeats the RAW decode, since these are the decoder's own controls.
    @Test("Detail slider render timings", .enabled(if: sampleDNG != nil))
    func detailTimings() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let view = CGSize(width: 2560, height: 1600)
        let size = try await renderer.render(fitting: view).photoSize
        let region = CGRect(x: 0.3, y: 0.3, width: view.width / size.width, height: view.height / size.height)
        let values: [Double] = [20, 35, 50, 65, 80, 95, 10]
        for (label, render) in [
            ("fitting 3456×2234", { (recipe: EditRecipe) in try await renderer.render(fitting: CGSize(width: 3456, height: 2234), recipe: recipe) }),
            ("region at 100%", { (recipe: EditRecipe) in try await renderer.render(region: region, scale: 1, recipe: recipe) }),
        ] as [(String, (EditRecipe) async throws -> RenderedPhoto)] {
            for keyPath in [\DetailAdjustments.sharpening, \.noiseReduction, \.colorNoiseReduction] {
                _ = try await render(EditRecipe())
                var times: [Double] = []
                for value in values {
                    var recipe = EditRecipe()
                    recipe.detail[keyPath: keyPath] = value
                    let start = ContinuousClock.now
                    _ = try await render(recipe)
                    times.append((ContinuousClock.now - start) / .milliseconds(1))
                }
                times.sort()
                print("Detail change \(keyPath) \(label): median \(String(format: "%.1f", times[times.count / 2])) ms, "
                    + "range \(String(format: "%.1f", times.first!))–\(String(format: "%.1f", times.last!)) ms")
            }
        }
    }

    private func pixels(_ photo: RenderedPhoto) throws -> [UInt8] {
        let image = try #require(CIImage(mtlTexture: photo.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
        let rowBytes = photo.texture.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * photo.texture.height)
        CIContext().render(image, toBitmap: &bytes, rowBytes: rowBytes, bounds: image.extent,
                           format: .RGBA8, colorSpace: RAWRenderer.colorSpace)
        return bytes
    }

    /// The mean squared Laplacian of the green channel: how much contrast sits in single-pixel detail.
    private func edgeEnergy(_ photo: RenderedPhoto) throws -> Double {
        let bytes = try pixels(photo)
        let width = photo.texture.width, height = photo.texture.height
        func green(_ x: Int, _ y: Int) -> Double { Double(bytes[(y * width + x) * 4 + 1]) }
        var sum = 0.0
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let laplacian = 4 * green(x, y) - green(x - 1, y) - green(x + 1, y) - green(x, y - 1) - green(x, y + 1)
                sum += laplacian * laplacian
            }
        }
        return sum / Double((width - 2) * (height - 2))
    }
}
