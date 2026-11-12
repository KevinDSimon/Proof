import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct EffectsTests {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
    ])

    // MARK: Recipe

    @Test("A file saved before Grain, Halation and Bloom reads them as off; a partial one keeps its other defaults")
    func migratesWithoutEffects() throws {
        let old = #"{"formatVersion": 3, "processVersion": 1, "vignette": {"amount": 0}}"#
        let recipe = try JSONDecoder().decode(EditRecipe.self, from: Data(old.utf8))
        #expect(recipe.grain == GrainAdjustments(amount: 0, size: 25, roughness: 50))
        #expect(recipe.halation == GlowAdjustments(amount: 0, size: 50))
        #expect(recipe.bloom == GlowAdjustments(amount: 0, size: 50))
        #expect(recipe.isNeutral && recipe.hasNoEffects)
        #expect(recipe.processVersion == 1)

        let partial = #"{"formatVersion": 3, "grain": {"amount": 30}, "halation": {"size": 80}}"#
        let read = try JSONDecoder().decode(EditRecipe.self, from: Data(partial.utf8))
        #expect(read.grain == GrainAdjustments(amount: 30))
        #expect(read.halation == GlowAdjustments(size: 80))

        var edited = recipe
        edited.grain = GrainAdjustments(amount: 40, size: 10, roughness: 90)
        edited.halation = GlowAdjustments(amount: 60, size: 20)
        edited.bloom = GlowAdjustments(amount: 15, size: 70)
        #expect(!edited.isNeutral && !edited.hasNoEffects)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]
        let grain = try #require(written?["grain"] as? [String: Any])
        #expect(grain["amount"] as? Double == 40 && grain["roughness"] as? Double == 90)
        let bloom = try #require(written?["bloom"] as? [String: Any])
        #expect(bloom["size"] as? Double == 70)
        #expect(try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(edited)) == edited)
    }

    @Test("The Effects card starts on for any effect, and switching it off removes all four")
    func effectsGroup() {
        for change in [{ (r: inout EditRecipe) in r.grain.amount = 10 }, { $0.halation.amount = 10 },
                       { $0.bloom.amount = 10 }, { $0.vignette.amount = -10 }] {
            var recipe = EditRecipe()
            change(&recipe)
            #expect(!AdjustmentGroup.initiallyOff(for: recipe).contains(.effects))
        }
        var recipe = EditRecipe()
        recipe.grain = GrainAdjustments(amount: 20)
        recipe.halation = GlowAdjustments(amount: 30)
        recipe.bloom = GlowAdjustments(amount: 40)
        recipe.vignette = VignetteAdjustments(amount: -50)
        recipe.basic.exposure = 1
        let off = recipe.without([.effects])
        #expect(off.hasNoEffects && off.basic == recipe.basic)
    }

    // MARK: Halation and Bloom

    @Test("With both Amounts at 0 the glow stage passes the image through untouched, whatever the sizes")
    func glowNeutralSkipsStage() {
        let image = lamp()
        #expect(Glow.apply(halation: GlowAdjustments(size: 90), bloom: GlowAdjustments(size: 10), to: image) === image)
        #expect(Glow.apply(halation: GlowAdjustments(amount: 10), bloom: GlowAdjustments(), to: image) !== image)
    }

    @Test("Halation puts a red fringe around a small light, with a little green and no blue, and fades with distance")
    func halationFringe() throws {
        let image = lamp()
        let result = Glow.apply(halation: GlowAdjustments(amount: 100), bloom: GlowAdjustments(), to: image)
        let near = try pixel(result, at: CGPoint(x: 312, y: 200))
        let far = try pixel(result, at: CGPoint(x: 20, y: 20))
        #expect(near.r > 0.05 + 0.01)
        #expect(near.g > 0.05 && near.g - 0.05 < (near.r - 0.05) / 2)
        #expect(abs(near.b - 0.05) < 0.0005)
        #expect(abs(far.r - 0.05) < (near.r - 0.05) / 10)
        // Size spreads it farther.
        let wide = Glow.apply(halation: GlowAdjustments(amount: 100, size: 100), bloom: GlowAdjustments(), to: image)
        let narrow = Glow.apply(halation: GlowAdjustments(amount: 100, size: 0), bloom: GlowAdjustments(), to: image)
        let point = CGPoint(x: 330, y: 200)
        #expect(try pixel(wide, at: point).r > pixel(narrow, at: point).r)
    }

    @Test("Inside an evenly bright area the glow leaves the color alone")
    func evenAreaKeepsColor() throws {
        // The left half white, as a clipped sky would be.
        let rect = CGRect(x: 0, y: 0, width: 600, height: 400)
        let image = CIImage(color: CIColor(red: 1, green: 1, blue: 1, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
            .composited(over: CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05, colorSpace: linear)!).cropped(to: rect))
        let result = Glow.apply(halation: GlowAdjustments(amount: 100), bloom: GlowAdjustments(), to: image)
        let inside = try pixel(result, at: CGPoint(x: 100, y: 200))
        #expect(abs(inside.r - inside.b) < 0.01)
        // Past its edge the light spills, but far less than a lamp near the clip point would.
        let outside = try pixel(result, at: CGPoint(x: 310, y: 200))
        #expect(outside.r > outside.b)
    }

    @Test("Bloom spreads a light in every color")
    func bloomInEveryColor() throws {
        let result = Glow.apply(halation: GlowAdjustments(), bloom: GlowAdjustments(amount: 100), to: lamp())
        let near = try pixel(result, at: CGPoint(x: 312, y: 200))
        #expect(near.r > 0.06 && near.g > 0.06 && near.b > 0.06)
        // In the light's own color, which is a little warm.
        #expect(near.b - 0.05 > (near.r - 0.05) * 0.6)
    }

    @Test("The glow is the same share of the photo at any render size")
    func glowScales() throws {
        let small = Glow.apply(halation: GlowAdjustments(amount: 100), bloom: GlowAdjustments(amount: 50), to: lamp(scale: 1))
        let large = Glow.apply(halation: GlowAdjustments(amount: 100), bloom: GlowAdjustments(amount: 50), to: lamp(scale: 4))
        for point in [CGPoint(x: 330, y: 200), CGPoint(x: 360, y: 230)] {
            let a = try pixel(small, at: point), b = try pixel(large, at: CGPoint(x: point.x * 4, y: point.y * 4))
            #expect(abs(a.r - b.r) < 0.01 && abs(a.g - b.g) < 0.01)
        }
    }

    // MARK: Grain

    @Test("With Amount at 0 the grain stage passes the image through untouched")
    func grainNeutralSkipsStage() {
        let image = gray(0.18)
        #expect(Grain.apply(GrainAdjustments(size: 90, roughness: 0), to: image) === image)
        #expect(Grain.apply(GrainAdjustments(amount: 10), to: image) !== image)
    }

    @Test("Grain varies the pixels without changing the average brightness, and Amount sets how much")
    func grainVaries() throws {
        let image = gray(0.18, width: 1200, height: 800)
        let light = try statistics(Grain.apply(GrainAdjustments(amount: 25), to: image))
        let strong = try statistics(Grain.apply(GrainAdjustments(amount: 100), to: image))
        #expect(light.deviation > 0.002)
        #expect(strong.deviation > light.deviation * 3)
        #expect(abs(strong.mean - 0.18) < 0.01)
    }

    @Test("A smaller render shows the grain of the full-size export shrunk to the same size")
    func grainMatchesExport() throws {
        let grain = GrainAdjustments(amount: 80, size: 25, roughness: 50)
        let preview = try statistics(Grain.apply(grain, to: gray(0.18, width: 600, height: 400)))
        let export = Grain.apply(grain, to: gray(0.18, width: 6000, height: 4000))
            .transformed(by: CGAffineTransform(scaleX: 0.1, y: 0.1), highQualityDownsample: true)
        let shrunk = try statistics(export)
        #expect(abs(preview.deviation - shrunk.deviation) < shrunk.deviation * 0.35)
    }

    // MARK: Speed

    /// See `TextureClarityTests.fullScreenTiming`: a slider drag renders at full size on every
    /// change, so with every effect in use a render has to finish within one 30 fps frame.
    @Test("An effect change renders within one frame at full-screen size", .enabled(if: sampleDNG != nil))
    func fullScreenTiming() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        var recipe = EditRecipe()
        recipe.vignette = VignetteAdjustments(amount: -30)
        recipe.grain = GrainAdjustments(amount: 30)
        recipe.halation = GlowAdjustments(amount: 40)
        recipe.bloom = GlowAdjustments(amount: 30)
        for target in [CGSize(width: 2880, height: 1800), CGSize(width: 3456, height: 2234)] {
            _ = try await renderer.render(fitting: target, recipe: recipe)
            var size = ""
            let times = try await frameTimes(for: Array(stride(from: 20.0, through: 100, by: 10))) { value in
                recipe.halation.size = value
                recipe.bloom.amount = value
                let photo = try await renderer.render(fitting: target, recipe: recipe)
                size = "\(photo.texture.width)×\(photo.texture.height)"
            }
            let median = times[times.count / 2]
            print("Effects render fitting \(Int(target.width))×\(Int(target.height)) (\(size)): median "
                + "\(String(format: "%.1f", median)) ms, "
                + "range \(String(format: "%.1f", times.first!))–\(String(format: "%.1f", times.last!)) ms")
            #expect(times.first! < frameBudget)
        }
    }

    // MARK: Helpers

    /// A dark 600×400 frame with a small light near the clip point at (300, 200), as a street
    /// light at night. `scale` renders the same frame larger.
    private func lamp(scale: CGFloat = 1) -> CIImage {
        let rect = CGRect(x: 0, y: 0, width: 600 * scale, height: 400 * scale)
        let light = CIImage(color: CIColor(red: 1, green: 0.95, blue: 0.85, colorSpace: linear)!)
            .cropped(to: CGRect(x: 294 * scale, y: 194 * scale, width: 12 * scale, height: 12 * scale))
        return light.composited(over: CIImage(color: CIColor(red: 0.05, green: 0.05, blue: 0.05, colorSpace: linear)!)
            .cropped(to: rect))
    }

    private func gray(_ value: CGFloat, width: CGFloat = 600, height: CGFloat = 400) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    /// The linear red, green and blue of the pixel at `point`.
    private func pixel(_ image: CIImage, at point: CGPoint) throws -> (r: Double, g: Double, b: Double) {
        var values = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &values, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: linear)
        return (Double(values[0]), Double(values[1]), Double(values[2]))
    }

    /// The mean and standard deviation of the green channel over a 200×200 patch in the middle.
    private func statistics(_ image: CIImage) throws -> (mean: Double, deviation: Double) {
        let extent = image.extent
        let patch = CGRect(x: (extent.midX - 100).rounded(), y: (extent.midY - 100).rounded(), width: 200, height: 200)
        var values = [Float](repeating: 0, count: 200 * 200 * 4)
        context.render(image, toBitmap: &values, rowBytes: 200 * 16, bounds: patch, format: .RGBAf, colorSpace: linear)
        let greens = stride(from: 1, to: values.count, by: 4).map { Double(values[$0]) }
        let mean = greens.reduce(0, +) / Double(greens.count)
        let variance = greens.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(greens.count)
        return (mean, variance.squareRoot())
    }
}
