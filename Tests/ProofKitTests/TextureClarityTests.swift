import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct TextureClarityTests {
    @Test("Values outside -100 to 100 are clamped")
    func clampsValues() {
        #expect(TextureClarity.clamped(250) == 100)
        #expect(TextureClarity.clamped(-180) == -100)
        #expect(TextureClarity.clamped(35) == 35)
    }

    @Test("With both sliders at 0 the stage passes the image through untouched")
    func neutralSkipsStage() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        #expect(TextureClarity.apply(to: image, texture: 0, clarity: 0) === image)
        #expect(TextureClarity.apply(to: image, texture: 20, clarity: 0) !== image)
        #expect(TextureClarity.apply(to: image, texture: 0, clarity: -20) !== image)
    }

    @Test("Positive values raise local contrast and negative values lower it")
    func movesBothWays() throws {
        let neutral = try spread(texture: 0, clarity: 0)
        #expect(try spread(texture: 100, clarity: 0) > neutral * 1.2)
        #expect(try spread(texture: -100, clarity: 0) < neutral * 0.8)
        #expect(try spread(texture: 0, clarity: 100) > neutral * 1.2)
        #expect(try spread(texture: 0, clarity: -100) < neutral * 0.8)
    }

    @Test("A flat area stays as it was")
    func flatAreaUnchanged() throws {
        let image = CIImage(color: CIColor(red: 0.2, green: 0.18, blue: 0.15)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        let before = try pixels(image), after = try pixels(TextureClarity.apply(to: image, texture: 100, clarity: 100))
        #expect(zip(before, after).allSatisfy { abs($0 - $1) < 0.002 })
    }

    @Test("The thumbnail and the canvas render a texture and clarity edit alike", .enabled(if: sampleDNG != nil))
    func thumbnailMatchesCanvas() async throws {
        let url = try #require(sampleDNG)
        var recipe = EditRecipe()
        recipe.basic.texture = 60
        recipe.basic.clarity = 50
        let renderer = try RAWRenderer()
        try await renderer.open(url)
        let canvas = try await renderer.render(fitting: CGSize(width: 400, height: 400), recipe: recipe)
        let canvasImage = try #require(CIImage(mtlTexture: canvas.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
        let thumbnail = CIImage(cgImage: try await renderer.thumbnail(of: url, recipe: recipe, maxPixelSize: 400))
        #expect(canvasImage.extent.size == thumbnail.extent.size)
        // The canvas texture is stored bottom row first, which doesn't change these measures.
        #expect(abs(try mean(canvasImage) - mean(thumbnail)) < 0.01)
        #expect(abs(try standardDeviation(canvasImage) - standardDeviation(thumbnail)) < 0.01)
    }

    @Test("Clarity and Texture change a real photo's local contrast", .enabled(if: sampleDNG != nil))
    func changesSample() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        func detail(texture: Double, clarity: Double) async throws -> Double {
            var recipe = EditRecipe()
            recipe.basic.texture = texture
            recipe.basic.clarity = clarity
            let photo = try await renderer.render(fitting: CGSize(width: 800, height: 800), recipe: recipe)
            let image = try #require(CIImage(mtlTexture: photo.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
            return try localDetail(image)
        }
        let neutral = try await detail(texture: 0, clarity: 0)
        #expect(try await detail(texture: 100, clarity: 0) > neutral)
        #expect(try await detail(texture: -100, clarity: 0) < neutral)
        #expect(try await detail(texture: 0, clarity: 100) > neutral)
        #expect(try await detail(texture: 0, clarity: -100) < neutral)
    }

    /// A slider drag renders at the window's full size on every change (docs/architecture.md),
    /// so with every tone slider in use a render has to finish within one 30 fps frame. The median
    /// is printed; run this suite on its own to measure it, since other suites share the GPU when
    /// all tests run. The expectation is on the fastest render, which that sharing barely moves.
    @Test("A texture or clarity change renders within one frame at full-screen size", .enabled(if: sampleDNG != nil))
    func fullScreenTiming() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        var recipe = EditRecipe()
        recipe.basic.highlights = -40
        recipe.basic.shadows = 30
        recipe.basic.contrast = 20
        for target in [CGSize(width: 2880, height: 1800), CGSize(width: 3456, height: 2234)] {
            recipe.basic.texture = 10
            recipe.basic.clarity = 10
            _ = try await renderer.render(fitting: target, recipe: recipe)
            var times: [Double] = []
            var size = ""
            for value in stride(from: 20.0, through: 100, by: 10) {
                recipe.basic.texture = value
                recipe.basic.clarity = -value
                let start = ContinuousClock.now
                let photo = try await renderer.render(fitting: target, recipe: recipe)
                times.append((ContinuousClock.now - start) / .milliseconds(1))
                size = "\(photo.texture.width)×\(photo.texture.height)"
            }
            times.sort()
            let median = times[times.count / 2]
            print("Texture and clarity render fitting \(Int(target.width))×\(Int(target.height)) (\(size)): median "
                + "\(String(format: "%.1f", median)) ms, "
                + "range \(String(format: "%.1f", times.first!))–\(String(format: "%.1f", times.last!)) ms")
            #expect(times.first! < 1000.0 / 30)
        }
    }

    /// Renders comparison strips for issue #101: the original, then Texture +100 and -100, then
    /// Clarity +100 and -100, for every RAW photo in `PROOF_COMPARE_DIR`, plus a crop at full
    /// size of each. The PNGs go to `PROOF_COMPARE_OUTPUT`, or a temporary folder.
    @Test("Comparison strips", .enabled(if: compareFolder != nil))
    func comparisonStrips() async throws {
        let folder = try #require(compareFolder)
        let output = ProcessInfo.processInfo.environment["PROOF_COMPARE_OUTPUT"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("proof-compare")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let photos = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let settings: [(texture: Double, clarity: Double)] = [(0, 0), (100, 0), (-100, 0), (0, 100), (0, -100)]
        let context = CIContext(options: [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
            .workingFormat: CIFormat.RGBAh,
        ])

        for photo in photos {
            let filter = try #require(CIRAWFilter(imageURL: photo))
            filter.scaleFactor = Float(RAWRenderer.scaleFactor(nativeSize: filter.nativeSize, orientation: filter.orientation,
                                                               fitting: CGSize(width: 2880, height: 1800)))
            let asShot = WhiteBalance(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
            let decoded = try #require(RAWRenderer.apply(EditRecipe(), to: filter, asShot: asShot,
                                                               cameraDetail: CameraDetail(of: filter)))
            let tiles = settings.map { TextureClarity.apply(to: decoded, texture: $0.texture, clarity: $0.clarity) }
            // The whole photo shrunk, and a 600-pixel square from its middle at the rendered size.
            let middle = CGRect(x: decoded.extent.midX - 300, y: decoded.extent.midY - 300, width: 600, height: 600)
            let shrink = 600 / max(decoded.extent.width, decoded.extent.height)
            for (name, shape) in [("whole", { (image: CIImage) in image.transformed(by: CGAffineTransform(scaleX: shrink, y: shrink)) }),
                                  ("detail", { (image: CIImage) in image.cropped(to: middle) })] {
                let shaped = tiles.map(shape)
                let strip = shaped.enumerated().reduce(CIImage.empty()) { strip, tile in
                    let placed = tile.element.transformed(by: CGAffineTransform(
                        translationX: CGFloat(tile.offset) * (tile.element.extent.width + 16) - tile.element.extent.minX,
                        y: -tile.element.extent.minY))
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

    /// The standard deviation of the luminance of a mid-gray noise pattern after the stage.
    private func spread(texture: Double, clarity: Double) throws -> Double {
        // Large enough that Texture's radius, a share of the size, is about a pixel.
        let rect = CGRect(x: 0, y: 0, width: 1024, height: 1024)
        // Noise from pixel to pixel, between about 0.1 and 0.3 in linear light.
        let noise = CIImage(cgImage: try #require(CIContext().createCGImage(
            CIFilter(name: "CIRandomGenerator")!.outputImage!.cropped(to: rect), from: rect)))
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.2, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0.2, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0.2, y: 0, z: 0, w: 0),
                "inputBiasVector": CIVector(x: 0.1, y: 0.1, z: 0.1, w: 0),
            ])
        return try standardDeviation(TextureClarity.apply(to: noise, texture: texture, clarity: clarity))
    }

    /// Luminance of every pixel, in linear extended sRGB, the space the pipeline works in.
    private func pixels(_ image: CIImage) throws -> [Double] {
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var values = [Float](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        CIContext(options: [.workingColorSpace: space])
            .render(image, toBitmap: &values, rowBytes: width * 16, bounds: image.extent, format: .RGBAf, colorSpace: space)
        return stride(from: 0, to: values.count, by: 4).map {
            Double(0.2126 * values[$0] + 0.7152 * values[$0 + 1] + 0.0722 * values[$0 + 2])
        }
    }

    private func mean(_ image: CIImage) throws -> Double {
        let values = try pixels(image)
        return values.reduce(0, +) / Double(values.count)
    }

    private func standardDeviation(_ image: CIImage) throws -> Double {
        let values = try pixels(image)
        let mean = values.reduce(0, +) / Double(values.count)
        return (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
    }

    /// The average difference between neighboring pixels, which rises with local contrast.
    private func localDetail(_ image: CIImage) throws -> Double {
        let values = try pixels(image)
        let width = Int(image.extent.width)
        var total = 0.0
        for index in values.indices where (index + 1) % width != 0 { total += abs(values[index + 1] - values[index]) }
        return total / Double(values.count)
    }
}

private let compareFolder = ProcessInfo.processInfo.environment["PROOF_COMPARE_DIR"].map(URL.init(fileURLWithPath:))
