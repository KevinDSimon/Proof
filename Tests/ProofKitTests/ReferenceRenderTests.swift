import CoreImage
import CryptoKit
import Foundation
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
    /// Each reference: its file name and the recipe it renders.
    static let references: [(name: String, recipe: EditRecipe)] = [
        ("neutral", EditRecipe()),
        ("edited", edited),
        ("contrast-whites-blacks", contrastWhitesBlacks),
        ("color", color),
        ("crop", crop),
        ("curve", curve),
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

    static let size = CGSize(width: 400, height: 400)
    /// Allows for rounding differences between GPUs, in 8-bit steps per channel.
    static let tolerance = 2

    @Test("Renders of the sample photo match the reference renders", .enabled(if: SampleFingerprint.matchesReferences))
    func matchesReferences() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        for reference in Self.references {
            let actual = try await image(renderer.render(fitting: Self.size, recipe: reference.recipe))
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
        for reference in Self.references {
            let photo = try await image(renderer.render(fitting: Self.size, recipe: reference.recipe))
            try CIContext().writePNGRepresentation(of: photo, to: referencesFolder.appendingPathComponent("\(reference.name).png"),
                                                   format: .RGBA8, colorSpace: RAWRenderer.colorSpace)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(try SampleFingerprint(of: url)).write(to: SampleFingerprint.file)
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
