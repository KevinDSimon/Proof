import Foundation
import Testing
@testable import ProofKit

struct AutoAdjustTests {
    /// A scene of grays and a few colored surfaces from 0.01 to 0.6 in linear light, lit by `light`.
    static func scene(lit light: SIMD3<Float>, count: Int = 4000) -> [SIMD3<Float>] {
        let surfaces: [SIMD3<Float>] = [[1, 1, 1], [1, 1, 1], [1, 1, 1], [0.9, 0.5, 0.3], [0.3, 0.6, 0.3], [0.4, 0.5, 0.9]]
        return (0..<count).map { i in
            let level = 0.01 + 0.59 * Float(i % 97) / 96
            return surfaces[i % surfaces.count] * light * level
        }
    }

    /// `count` luminances spread evenly in stops from `low` to `high`.
    static func luminances(from low: Double, to high: Double, count: Int = 4000) -> [Float] {
        (0..<count).map { i in Float(low * pow(high / low, Double(i) / Double(count - 1))) }
    }

    @Test("A scene in white light has no cast")
    func neutralScene() throws {
        let cast = try #require(AutoAdjust.cast(of: Self.scene(lit: [1, 1, 1])))
        #expect(cast.size < 0.01)
    }

    @Test("Blue light reads as too blue, green light as too green")
    func castDirection() throws {
        let blue = try #require(AutoAdjust.cast(of: Self.scene(lit: [0.8, 1, 1.25])))
        #expect(abs(blue.blueYellow - log2(1.25 / 0.8)) < 0.05)
        #expect(abs(blue.greenMagenta) < 0.05)
        let green = try #require(AutoAdjust.cast(of: Self.scene(lit: [1, 1.2, 1])))
        #expect(abs(green.greenMagenta - log2(1.2)) < 0.05)
        #expect(abs(green.blueYellow) < 0.05)
    }

    @Test("Clipped pixels don't count toward the cast")
    func ignoresClipping() throws {
        var pixels = Self.scene(lit: [1, 1, 1])
        // A blown sky, clipped in red and green but not blue.
        pixels += Array(repeating: [1, 1, 0.7], count: 400)
        let cast = try #require(AutoAdjust.cast(of: pixels))
        #expect(cast.size < 0.02)
    }

    @Test("A black frame has no cast to judge")
    func blackFrame() {
        #expect(AutoAdjust.cast(of: Array(repeating: [0, 0, 0], count: 1000)) == nil)
    }

    @Test("A patch picked as neutral reads its plain color as the cast")
    func neutralPatch() throws {
        // A gray card under warm light, with some noise.
        let patch: [SIMD3<Float>] = (0..<64).map { i in [0.25, 0.2, 0.16] * (0.95 + 0.1 * Float(i % 5) / 4) }
        let cast = try #require(AutoAdjust.cast(ofNeutral: patch))
        #expect(abs(cast.blueYellow - log2(0.16 / 0.25)) < 0.01)
        #expect(abs(cast.greenMagenta - log2(0.2 / (0.25 * 0.16).squareRoot())) < 0.01)
    }

    @Test("A black patch has no color to pick")
    func blackPatch() {
        #expect(AutoAdjust.cast(ofNeutral: Array(repeating: [0.001, 0.001, 0.001], count: 64)) == nil)
        #expect(AutoAdjust.cast(ofNeutral: []) == nil)
    }

    /// A stand-in for the RAW decoder: the cast changes smoothly, and not quite in a straight
    /// line, with the temperature in mireds and the tint, and is neutral at 4300 K and +14.
    static func modelCast(_ wb: WhiteBalance) -> AutoAdjust.Cast {
        let mireds = 1e6 / wb.temperature - 1e6 / 4300, tint = wb.tint - 14
        return AutoAdjust.Cast(blueYellow: 0.006 * mireds + 0.00002 * mireds * abs(mireds) + 0.001 * tint,
                               greenMagenta: -0.008 * tint + 0.0005 * mireds)
    }

    @Test("The white balance search finds the neutral setting from As Shot")
    func searchConverges() throws {
        for start in [WhiteBalance(temperature: 6500, tint: 0), WhiteBalance(temperature: 2600, tint: -30),
                      WhiteBalance(temperature: 12000, tint: 40)] {
            var renders = 0
            let found = try #require(AutoAdjust.whiteBalance(from: start) { renders += 1; return Self.modelCast($0) })
            #expect(abs(found.temperature - 4300) <= 30)
            #expect(abs(found.tint - 14) <= 1)
            #expect(renders <= 9)
        }
    }

    @Test("The white balance search stays within the sliders' ranges")
    func searchClamps() throws {
        let found = try #require(AutoAdjust.whiteBalance(from: WhiteBalance(temperature: 5000, tint: 0)) { wb in
            AutoAdjust.Cast(blueYellow: 0.01 * (1e6 / wb.temperature - 1e6 / 1000), greenMagenta: -0.01 * (wb.tint - 400))
        })
        #expect(found.temperature == WhiteBalance.temperatureRange.lowerBound)
        #expect(found.tint == WhiteBalance.tintRange.upperBound)
    }

    @Test("A photo that already reaches near white isn't brightened much")
    func nearWhite() {
        let light = AutoAdjust.tone(luminances: Self.luminances(from: 0.004, to: 0.85))
        #expect(light.exposure >= 0 && light.exposure <= 0.3)
        #expect(light.highlights >= -15)
    }

    @Test("Exposure follows how far a photo is under or over")
    func exposure() {
        let normal = AutoAdjust.tone(luminances: Self.luminances(from: 0.004, to: 0.85))
        let dark = AutoAdjust.tone(luminances: Self.luminances(from: 0.004 / 4, to: 0.85 / 4))
        #expect(abs(dark.exposure - normal.exposure - 2) <= 0.1)
        let bright = AutoAdjust.tone(luminances: Self.luminances(from: 0.004 * 2, to: 0.85 * 2))
        #expect(abs(bright.exposure - normal.exposure + 1) <= 0.1)
    }

    @Test("A bright sky over a dark foreground holds the sky and lifts the foreground")
    func brightSky() {
        // Like the sample photo: rock around 0.015 and sky around 0.5.
        let light = AutoAdjust.tone(luminances: Self.luminances(from: 0.002, to: 0.05, count: 2500)
            + Self.luminances(from: 0.35, to: 0.55, count: 1500))
        #expect(light.exposure > 0.4 && light.exposure < 1)
        #expect(light.shadows > 15)
        #expect(light.highlights > -30)
    }

    @Test("A photo with more range than fits pulls back highlights and lifts shadows")
    func wideRange() {
        let light = AutoAdjust.tone(luminances: Self.luminances(from: 0.0002, to: 8))
        #expect(light.highlights < -30)
        #expect(light.shadows > 15)
        #expect(light.contrast < 0)
    }

    @Test("A flat, hazy photo gets more contrast and deeper blacks")
    func flatPhoto() {
        let light = AutoAdjust.tone(luminances: Self.luminances(from: 0.06, to: 0.5))
        #expect(light.contrast > 15)
        #expect(light.blacks < -15)
        #expect(light.whites > 0)
    }

    @Test("Auto stays within limits on a black frame")
    func blackLight() {
        #expect(AutoAdjust.tone(luminances: Array(repeating: 0, count: 1000)) == AutoAdjust.Tone())
    }

    @Test("Auto measures the photo without the tone, color and look already set")
    func measuringRecipe() {
        var recipe = EditRecipe()
        recipe.basic.setTemperature(4800)
        recipe.basic.exposure = 1.5
        recipe.basic.contrast = 40
        recipe.basic.vibrance = 20
        recipe.curve.rgb = [CurvePoint(0, 0.1), CurvePoint(1, 1)]
        recipe.crop = Crop(rotation: 90)
        let measured = RAWRenderer.measuring(recipe)
        #expect(measured.basic.temperature == 4800)
        #expect(measured.crop == recipe.crop)
        #expect(measured.basic.exposure == 0 && measured.basic.contrast == 0 && measured.basic.vibrance == 0)
        #expect(measured.curve == ToneCurve())
    }

    /// RAW files can't be committed, so these run only when `PROOF_SAMPLE_DNG` names one.
    @Test("On a real photo, Auto white balance stays in range and repeats exactly",
          .enabled(if: sampleDNG != nil))
    func sampleWhiteBalance() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let start = ContinuousClock.now
        let found = try await renderer.autoWhiteBalance(recipe: EditRecipe())
        let elapsed = ContinuousClock.now - start
        print("Auto white balance: \(found) in \(elapsed)")
        #expect(try await renderer.autoWhiteBalance(recipe: EditRecipe()) == found)
        #expect(WhiteBalance.temperatureRange.contains(found.temperature))
    }

    @Test("On a real photo, the eyedropper leaves the picked patch neutral, from any starting white balance",
          .enabled(if: sampleDNG != nil))
    func sampleEyedropper() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let patch = CGRect(x: 0.495, y: 0.495, width: 0.01, height: 0.01)
        var recipe = EditRecipe()
        let start = ContinuousClock.now
        let found = try #require(try await renderer.whiteBalance(neutralIn: patch, recipe: recipe))
        print("Eyedropper: \(found) in \(ContinuousClock.now - start)")
        #expect(WhiteBalance.temperatureRange.contains(found.temperature))
        recipe.basic.setTemperature(2500)
        recipe.basic.setTint(60)
        let again = try #require(try await renderer.whiteBalance(neutralIn: patch, recipe: recipe))
        #expect(again == found)
    }

    @Test("On a real photo, Auto Tone chooses moderate values and repeats exactly",
          .enabled(if: sampleDNG != nil))
    func sampleLight() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        var recipe = EditRecipe()
        let light = try await renderer.autoTone(recipe: recipe)
        print("Auto Tone: \(light)")
        #expect(abs(light.exposure) <= 3)
        // The Tone sliders already set don't change what Auto chooses.
        recipe.basic.exposure = 2
        recipe.basic.highlights = -80
        #expect(try await renderer.autoTone(recipe: recipe) == light)
    }
}
