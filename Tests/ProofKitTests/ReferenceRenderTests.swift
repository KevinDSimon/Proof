import CoreImage
import CryptoKit
import Foundation
import simd
import Testing
@testable import ProofKit

/// Compares renders of the sample photo with PNGs in `References/`, so a change that alters
/// pixels shows up in a test. RAW files can't be committed, so the PNGs are kept with a
/// fingerprint of the photo they came from, and the comparison runs only when
/// `PROOF_SAMPLE_DNG` names that same photo.
///
/// To record new references after an intended change, run
/// `PROOF_SAMPLE_DNG=<photo> PROOF_RECORD_REFERENCES=1 swift test --filter ReferenceRenderTests`
/// and say in the pull request which renders changed and why.
struct ReferenceRenderTests {
    /// Each reference: its file name, the recipe it renders and the LUT its look names.
    static let references: [(name: String, recipe: EditRecipe, lut: PreparedLUT?)] = [
        ("neutral", EditRecipe(), nil),
        ("edited", edited, nil),
        ("contrast-whites-blacks", contrastWhitesBlacks, nil),
        ("color", color, nil),
        ("crop", crop, nil),
        ("curve", curve, nil),
        ("look", look, PreparedLUT(lookTable)),
        ("texture", texture, nil),
        ("clarity", clarity, nil),
    ]

    /// Uses every adjustment the pipeline applies so far. As later stages are built, add their
    /// adjustments here and record the edited reference again.
    static let edited: EditRecipe = {
        var recipe = EditRecipe()
        recipe.basic.whiteBalance = .custom
        recipe.basic.temperature = 4800
        recipe.basic.tint = 12
        recipe.basic.exposure = 0.7
        recipe.basic.highlights = -60
        recipe.basic.shadows = 40
        recipe.basic.contrast = 25
        recipe.basic.whites = 20
        recipe.basic.blacks = -15
        recipe.basic.vibrance = 30
        recipe.basic.saturation = -10
        recipe.curve.rgb = [CurvePoint(0, 0.03), CurvePoint(0.3, 0.26), CurvePoint(0.7, 0.75), CurvePoint(1, 1)]
        recipe.curve.blue = [CurvePoint(0, 0), CurvePoint(0.5, 0.47), CurvePoint(1, 1)]
        return recipe
    }()

    /// The tone lookup alone, strong enough that a change to its curve shows.
    static let contrastWhitesBlacks: EditRecipe = {
        var recipe = EditRecipe()
        recipe.basic.contrast = 50
        recipe.basic.whites = 40
        recipe.basic.blacks = -40
        return recipe
    }()

    /// Texture alone, at its strongest, so a change to its radius or strength shows.
    static let texture: EditRecipe = {
        var recipe = EditRecipe()
        recipe.basic.texture = 100
        return recipe
    }()

    /// Clarity alone, at its strongest, so a change to its area, strength or midtone range shows.
    static let clarity: EditRecipe = {
        var recipe = EditRecipe()
        recipe.basic.clarity = 100
        return recipe
    }()

    /// The tone curve alone: an S-curve on RGB with its ends moved, a different curve on each
    /// color channel, and levels on RGB and green, so a change to the interpolation, the levels,
    /// the order or a channel shows.
    static let curve: EditRecipe = {
        var recipe = EditRecipe()
        recipe.curve.rgb = [CurvePoint(0.04, 0), CurvePoint(0.25, 0.18), CurvePoint(0.75, 0.84), CurvePoint(0.97, 1)]
        recipe.curve.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.55), CurvePoint(1, 1)]
        recipe.curve.green = [CurvePoint(0, 0.03), CurvePoint(1, 1)]
        recipe.curve.blue = [CurvePoint(0, 0), CurvePoint(0.6, 0.55), CurvePoint(1, 0.95)]
        recipe.curve.levels.rgb = Levels(black: 0.02, midtone: 0.45, white: 0.96)
        recipe.curve.levels.green = Levels(black: 0, midtone: 0.55, white: 1)
        return recipe
    }()

    /// A LUT alone, at part strength, so a change to the cube, the color space it is applied
    /// in or the blend shows.
    static let look: EditRecipe = {
        var recipe = EditRecipe()
        recipe.look = Look(lut: "Reference.cube", strength: 0.6)
        return recipe
    }()

    /// A film-like grade that moves every channel differently: warmer highlights, teal shadows,
    /// lifted blacks and less saturation. Written out here so the reference doesn't depend on a file.
    static let lookTable: CubeLUT = {
        let size = 33
        var values = [SIMD3<Float>]()
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let c = SIMD3(Float(r), Float(g), Float(b)) / Float(size - 1)
                    let luma = (c * SIMD3(0.2126, 0.7152, 0.0722)).sum()
                    let muted = luma + (c - luma) * 0.8
                    let tint = SIMD3<Float>(0.06, 0.01, -0.05) * luma + SIMD3<Float>(-0.03, 0.01, 0.03) * (1 - luma)
                    values.append(simd_clamp(0.04 + muted * 0.94 + tint, .zero, .one))
                }
            }
        }
        return CubeLUT(kind: .threeDimensional, size: size, values: values)
    }()

    /// Vibrance and saturation alone, strong enough that a change to either filter shows.
    static let color: EditRecipe = {
        var recipe = EditRecipe()
        recipe.basic.vibrance = 60
        recipe.basic.saturation = 25
        return recipe
    }()

    /// A quarter turn, a flip and a straightened 4:5 crop, so a change to any part of the
    /// geometry stage, or to its order, shows.
    static let crop: EditRecipe = {
        var crop = Crop(aspect: AspectRatio(4, 5))
        crop.rotate(clockwise: true)
        crop.flipHorizontally()
        let turned = crop.turnedSize(of: CGSize(width: 3, height: 2))
        crop = CropFrame.whole(turned).withAspect(crop.aspect).straightened(6)
            .moved(by: CGVector(dx: 0, dy: -1)).applied(to: crop)
        var recipe = EditRecipe()
        recipe.crop = crop
        return recipe
    }()

    /// Sharpening and noise reduction, rendered at 100% on a region at the photo's center, since
    /// the decoder sharpens only above half size. The camera's own detail is kept as a reference
    /// too, so a change to the defaults shows. The sample is ISO 64, where the decoder's luminance
    /// noise reduction does almost nothing, so the noise reduction render mostly shows color.
    static let detailReferences: [(name: String, recipe: EditRecipe)] = [
        ("detail-camera", EditRecipe()),
        ("sharpening", EditRecipe(detail: DetailAdjustments(sharpening: 100))),
        ("noise-reduction", EditRecipe(detail: DetailAdjustments(sharpening: 0, noiseReduction: 100,
                                                                 noiseReductionDetail: 0, colorNoiseReduction: 100))),
    ]

    static let size = CGSize(width: 400, height: 400)
    /// Allows for rounding differences between GPUs, in 8-bit steps per channel.
    static let tolerance = 2

    @Test("Renders of the sample photo match the reference renders", .enabled(if: SampleFingerprint.matchesReferences))
    func matchesReferences() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        for reference in try await renders(renderer) {
            let actual = reference.image
            let expected = try #require(CIImage(contentsOf: referencesFolder.appendingPathComponent("\(reference.name).png")))
            #expect(actual.extent == expected.extent, "\(reference.name): size changed")
            guard actual.extent == expected.extent else { continue }
            let difference = largestDifference(pixels(actual), pixels(expected))
            #expect(difference <= Self.tolerance, "\(reference.name): a channel differs by \(difference) steps")
        }
    }

    @Test("Record the reference renders", .enabled(if: sampleDNG != nil && isRecording))
    func record() async throws {
        let url = try #require(sampleDNG)
        let renderer = try RAWRenderer()
        try await renderer.open(url)
        try FileManager.default.createDirectory(at: referencesFolder, withIntermediateDirectories: true)
        for reference in try await renders(renderer) {
            try CIContext().writePNGRepresentation(of: reference.image, to: referencesFolder.appendingPathComponent("\(reference.name).png"),
                                                   format: .RGBA8, colorSpace: RAWRenderer.colorSpace)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(try SampleFingerprint(of: url)).write(to: SampleFingerprint.file)
    }

    /// Every reference rendered from the open photo, named as its PNG.
    private func renders(_ renderer: RAWRenderer) async throws -> [(name: String, image: CIImage)] {
        var result: [(name: String, image: CIImage)] = []
        for reference in Self.references {
            result.append((reference.name, try await image(renderer.render(fitting: Self.size, recipe: reference.recipe,
                                                                            lut: reference.lut))))
        }
        let photo = try await renderer.render(fitting: Self.size).photoSize
        let region = CGRect(x: 0.5 - Self.size.width / photo.width / 2, y: 0.5 - Self.size.height / photo.height / 2,
                            width: Self.size.width / photo.width, height: Self.size.height / photo.height)
        for reference in Self.detailReferences {
            result.append((reference.name, try await image(renderer.render(region: region, scale: 1, recipe: reference.recipe))))
        }
        return result
    }

    private func image(_ photo: RenderedPhoto) throws -> CIImage {
        try #require(CIImage(mtlTexture: photo.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
    }

    private func pixels(_ image: CIImage) -> [UInt8] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        CIContext().render(image, toBitmap: &bytes, rowBytes: width * 4, bounds: image.extent,
                           format: .RGBA8, colorSpace: RAWRenderer.colorSpace)
        return bytes
    }

    private func largestDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).reduce(0) { max($0, abs(Int($1.0) - Int($1.1))) }
    }
}

/// Identifies the photo the references were rendered from.
struct SampleFingerprint: Codable, Equatable {
    var fileName: String
    var byteCount: Int
    var sha256: String

    init(of url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        fileName = url.lastPathComponent
        byteCount = data.count
        sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static let file = referencesFolder.appendingPathComponent("sample.json")

    static var matchesReferences: Bool {
        guard let sampleDNG, !isRecording,
              let data = try? Data(contentsOf: file),
              let recorded = try? JSONDecoder().decode(SampleFingerprint.self, from: data)
        else { return false }
        return (try? SampleFingerprint(of: sampleDNG)) == recorded
    }
}

private let referencesFolder = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .appendingPathComponent("References")

private let isRecording = ProcessInfo.processInfo.environment["PROOF_RECORD_REFERENCES"] == "1"
