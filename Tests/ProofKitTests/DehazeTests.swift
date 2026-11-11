import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct DehazeTests {
    @Test("Values outside -100 to 100 are clamped")
    func clampsValues() {
        #expect(Dehaze.clamped(250) == 100)
        #expect(Dehaze.clamped(-180) == -100)
        #expect(Dehaze.clamped(35) == 35)
    }

    @Test("At 0 the stage passes the image through untouched")
    func neutralSkipsStage() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        #expect(Dehaze.apply(to: image, amount: 0) === image)
        #expect(Dehaze.apply(to: image, amount: 20) !== image)
    }

    @Test("Removing haze raises the contrast of a hazy scene and adding haze lowers it")
    func movesBothWays() throws {
        let neutral = try standardDeviation(hazyScene())
        #expect(try standardDeviation(Dehaze.apply(to: hazyScene(), amount: 100)) > neutral * 1.5)
        #expect(try standardDeviation(Dehaze.apply(to: hazyScene(), amount: -100)) < neutral * 0.7)
    }

    @Test("Removing haze takes out the haze's color and leaves the scene's")
    func removesHazeColor() throws {
        // Dark red and dark green squares under a pale blue haze.
        let values = try rgb(Dehaze.apply(to: hazyScene(), amount: 100))
        let red = values[0], green = values[1]
        #expect(red.r > red.b && red.r > red.g)
        #expect(green.g > green.r && green.g > green.b)
    }

    @Test("Dehaze changes a real photo and the thumbnail matches the canvas", .enabled(if: sampleDNG != nil))
    func thumbnailMatchesCanvas() async throws {
        let url = try #require(sampleDNG)
        var recipe = EditRecipe()
        recipe.basic.dehaze = 60
        let renderer = try RAWRenderer()
        try await renderer.open(url)
        let canvas = try await renderer.render(fitting: CGSize(width: 400, height: 400), recipe: recipe)
        let canvasImage = try #require(CIImage(mtlTexture: canvas.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
        let thumbnail = CIImage(cgImage: try await renderer.thumbnail(of: url, recipe: recipe, maxPixelSize: 400))
        #expect(canvasImage.extent.size == thumbnail.extent.size)
        #expect(abs(try mean(canvasImage) - mean(thumbnail)) < 0.01)
        #expect(abs(try standardDeviation(canvasImage) - standardDeviation(thumbnail)) < 0.01)
        let neutral = try await renderer.render(fitting: CGSize(width: 400, height: 400), recipe: EditRecipe())
        let neutralImage = try #require(CIImage(mtlTexture: neutral.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
        #expect(try localDetail(canvasImage) > localDetail(neutralImage))
    }

    /// See `TextureClarityTests.fullScreenTiming`: a slider drag renders at full size on every
    /// change, so with every tone slider in use a render has to finish within one 30 fps frame.
    @Test("A dehaze change renders within one frame at full-screen size", .enabled(if: sampleDNG != nil))
    func fullScreenTiming() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        var recipe = EditRecipe()
        recipe.basic.highlights = -40
        recipe.basic.shadows = 30
        recipe.basic.contrast = 20
        recipe.basic.clarity = 20
        for target in [CGSize(width: 2880, height: 1800), CGSize(width: 3456, height: 2234)] {
            recipe.basic.dehaze = 10
            _ = try await renderer.render(fitting: target, recipe: recipe)
            var size = ""
            let times = try await frameTimes(for: Array(stride(from: 20.0, through: 100, by: 10))) { value in
                recipe.basic.dehaze = value
                let photo = try await renderer.render(fitting: target, recipe: recipe)
                size = "\(photo.texture.width)×\(photo.texture.height)"
            }
            let median = times[times.count / 2]
            print("Dehaze render fitting \(Int(target.width))×\(Int(target.height)) (\(size)): median "
                + "\(String(format: "%.1f", median)) ms, "
                + "range \(String(format: "%.1f", times.first!))–\(String(format: "%.1f", times.last!)) ms")
            #expect(times.first! < frameBudget)
        }
    }

    /// Renders comparison strips for issue #26: the original, then Dehaze +50, +100, -50 and -100, for every RAW photo in `PROOF_COMPARE_DIR`, plus a crop at full
    /// size of each. The PNGs go to `PROOF_COMPARE_OUTPUT`, or a temporary folder.
    @Test("Dehaze comparison strips", .enabled(if: dehazeCompareFolder != nil))
    func comparisonStrips() async throws {
        let folder = try #require(dehazeCompareFolder)
        let output = ProcessInfo.processInfo.environment["PROOF_COMPARE_OUTPUT"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("proof-compare")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let photos = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let settings: [Double] = [0, 50, 100, -50, -100]
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
                                                               cameraDetail: CameraDetail(of: filter), cameraLens: CameraLens(of: filter)))
            let tiles = settings.map { Dehaze.apply(to: decoded, amount: $0) }
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
                let file = output.appendingPathComponent("\(photo.deletingPathExtension().lastPathComponent)-dehaze-\(name).png")
                let background = CIImage(color: .white).cropped(to: strip.extent)
                try context.writePNGRepresentation(of: strip.composited(over: background), to: file,
                                                   format: .RGBA8, colorSpace: RAWRenderer.colorSpace)
                print("Comparison strip: \(file.path)")
            }
        }
    }

    /// Two dark squares, red and green, on a dark gray ground, all under a pale blue haze that
    /// lets 40% of their light through, as in `I = J·t + A·(1 − t)`.
    private func hazyScene() -> CIImage {
        let haze = CIColor(red: 0.6, green: 0.7, blue: 0.8)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        func hazy(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CIImage {
            CIImage(color: CIColor(red: r * 0.4 + haze.red * 0.6, green: g * 0.4 + haze.green * 0.6,
                                   blue: b * 0.4 + haze.blue * 0.6, colorSpace: linear)!)
        }
        let rect = CGRect(x: 0, y: 0, width: 512, height: 256)
        let red = hazy(0.3, 0.03, 0.02).cropped(to: CGRect(x: 32, y: 64, width: 128, height: 128))
        let green = hazy(0.03, 0.25, 0.02).cropped(to: CGRect(x: 352, y: 64, width: 128, height: 128))
        return red.composited(over: green).composited(over: hazy(0.05, 0.05, 0.05)).cropped(to: rect)
    }

    /// The red, green and blue in the middle of the scene's red and green squares.
    private func rgb(_ image: CIImage) throws -> [(r: Float, g: Float, b: Float)] {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let context = CIContext(options: [.workingColorSpace: space])
        return [CGPoint(x: 96, y: 128), CGPoint(x: 416, y: 128)].map { point in
            var value = [Float](repeating: 0, count: 4)
            context.render(image, toBitmap: &value, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                           format: .RGBAf, colorSpace: space)
            return (value[0], value[1], value[2])
        }
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

private let dehazeCompareFolder = ProcessInfo.processInfo.environment["PROOF_COMPARE_DIR"].map(URL.init(fileURLWithPath:))
