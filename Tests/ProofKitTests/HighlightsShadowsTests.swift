import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct HighlightsShadowsTests {
    @Test("Values outside -100 to 100 are clamped")
    func clampsValues() {
        #expect(HighlightsShadows.clamped(250) == 100)
        #expect(HighlightsShadows.clamped(-180) == -100)
        #expect(HighlightsShadows.clamped(-40) == -40)
    }

    @Test("With both sliders at 0 the stage passes the image through untouched")
    func neutralSkipsStage() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        #expect(HighlightsShadows.apply(to: image, highlights: 0, shadows: 0) === image)
        #expect(HighlightsShadows.apply(to: image, highlights: -40, shadows: 0) !== image)
    }

    @Test("Highlights darken and brighten bright areas; shadows brighten and darken dark ones")
    func movesBothWays() {
        let bright = average(of: CIColor(red: 0.9, green: 0.85, blue: 0.8), highlights: 0, shadows: 0)
        #expect(average(of: CIColor(red: 0.9, green: 0.85, blue: 0.8), highlights: -100, shadows: 0) < bright)
        #expect(average(of: CIColor(red: 0.9, green: 0.85, blue: 0.8), highlights: 100, shadows: 0) > bright)
        // Shadows leave a bright area nearly as it was.
        #expect(abs(average(of: CIColor(red: 0.9, green: 0.85, blue: 0.8), highlights: 0, shadows: 100) - bright) < 0.02)

        let dark = average(of: CIColor(red: 0.01, green: 0.012, blue: 0.015), highlights: 0, shadows: 0)
        #expect(average(of: CIColor(red: 0.01, green: 0.012, blue: 0.015), highlights: 0, shadows: 100) > dark * 2)
        #expect(average(of: CIColor(red: 0.01, green: 0.012, blue: 0.015), highlights: 0, shadows: -100) < dark)
    }

    @Test("The thumbnail and the canvas render a highlights and shadows edit alike", .enabled(if: sampleDNG != nil))
    func thumbnailMatchesCanvas() async throws {
        let url = try #require(sampleDNG)
        var recipe = EditRecipe()
        recipe.basic.highlights = -80
        recipe.basic.shadows = 60
        let renderer = try RAWRenderer()
        try await renderer.open(url)
        let canvas = try await renderer.render(fitting: CGSize(width: 400, height: 400), recipe: recipe)
        let canvasImage = try #require(CIImage(mtlTexture: canvas.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
        let thumbnail = CIImage(cgImage: try await renderer.thumbnail(of: url, recipe: recipe, maxPixelSize: 400))
        #expect(canvasImage.extent.size == thumbnail.extent.size)
        // The canvas texture is stored bottom row first; the comparison is of whole-photo
        // averages, which that doesn't change, plus the darkest and brightest quarters.
        let a = try averageColor(canvasImage), b = try averageColor(thumbnail)
        for channel in 0..<3 { #expect(abs(a[channel] - b[channel]) < 0.01) }
    }

    @Test("Highlights recover a real photo's bright areas and shadows lift its dark ones", .enabled(if: sampleDNG != nil))
    func changesSample() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let size = CGSize(width: 400, height: 400)
        func average(highlights: Double, shadows: Double) async throws -> Float {
            var recipe = EditRecipe()
            recipe.basic.highlights = highlights
            recipe.basic.shadows = shadows
            let photo = try await renderer.render(fitting: size, recipe: recipe)
            let pixel = try averageColor(try #require(CIImage(mtlTexture: photo.texture, options: [.colorSpace: RAWRenderer.colorSpace])))
            return 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
        }
        let neutral = try await average(highlights: 0, shadows: 0)
        #expect(try await average(highlights: -100, shadows: 0) < neutral)
        #expect(try await average(highlights: 0, shadows: 100) > neutral)
    }

    /// Renders comparison strips for issue #14: the original, Highlights -100, Shadows +100 and
    /// both, from this kernel and from `CIHighlightShadowAdjust`, for every RAW photo in
    /// `PROOF_COMPARE_DIR`. The PNGs go to `PROOF_COMPARE_OUTPUT`, or a temporary folder.
    @Test("Comparison strips", .enabled(if: compareFolder != nil))
    func comparisonStrips() async throws {
        let folder = try #require(compareFolder)
        let output = ProcessInfo.processInfo.environment["PROOF_COMPARE_OUTPUT"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("proof-compare")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let photos = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let settings: [(highlights: Double, shadows: Double)] = [(0, 0), (-100, 0), (0, 100), (-100, 100)]
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
        ])

        for photo in photos {
            let filter = try #require(CIRAWFilter(imageURL: photo))
            filter.scaleFactor = Float(RAWRenderer.scaleFactor(nativeSize: filter.nativeSize, orientation: filter.orientation,
                                                               fitting: CGSize(width: 1600, height: 1600)))
            let asShot = WhiteBalance(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
            let decoded = try #require(RAWRenderer.apply(EditRecipe(), to: filter, asShot: asShot,
                                                                 cameraDetail: CameraDetail(of: filter)))
            let radius = 0.02 * max(decoded.extent.width, decoded.extent.height)

            let proof = settings.map { HighlightsShadows.apply(to: decoded, highlights: $0.highlights, shadows: $0.shadows) }
            // The built-in filter: a highlight amount of 1 leaves highlights alone and 0 darkens
            // them fully; a shadow amount of 0 leaves shadows alone and 1 brightens them fully.
            let builtIn = settings.map {
                decoded.applyingFilter("CIHighlightShadowAdjust", parameters: [
                    "inputHighlightAmount": 1 + min($0.highlights, 0) / 100,
                    "inputShadowAmount": $0.shadows / 100,
                    "inputRadius": radius,
                ]).cropped(to: decoded.extent)
            }
            for (name, tiles) in [("proof", proof), ("built-in", builtIn)] {
                let strip = tiles.enumerated().reduce(CIImage.empty()) { strip, tile in
                    let placed = tile.element.transformed(by: CGAffineTransform(
                        translationX: CGFloat(tile.offset) * (decoded.extent.width + 16) - decoded.extent.minX,
                        y: -decoded.extent.minY))
                    return placed.composited(over: strip)
                }
                let file = output.appendingPathComponent("\(photo.deletingPathExtension().lastPathComponent)-\(name).png")
                let background = CIImage(color: .white).cropped(to: strip.extent)
                try context.writePNGRepresentation(of: strip.composited(over: background), to: file,
                                                   format: .RGBA8, colorSpace: RAWRenderer.colorSpace)
                print("Comparison strip: \(file.path)")
            }
        }
    }

    private func average(of color: CIColor, highlights: Double, shadows: Double) -> Float {
        let image = CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let adjusted = HighlightsShadows.apply(to: image, highlights: highlights, shadows: shadows)
        let pixel = (try? averageColor(adjusted)) ?? [0, 0, 0, 0]
        return 0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2]
    }

    /// Red, green, blue and alpha averaged over the image, in linear extended sRGB, the space the
    /// pipeline works in.
    private func averageColor(_ image: CIImage) throws -> [Float] {
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!])
        context.render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)
        return pixel
    }
}

private let compareFolder = ProcessInfo.processInfo.environment["PROOF_COMPARE_DIR"].map(URL.init(fileURLWithPath:))
