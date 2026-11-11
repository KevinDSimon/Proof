import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct VignetteTests {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAh,
    ])

    @Test("With Amount at 0 the stage passes the image through untouched, whatever the shape")
    func neutralSkipsStage() {
        let image = gray(0.18)
        #expect(Vignette.apply(VignetteAdjustments(midpoint: 10, roundness: 80, feather: 0), to: image) === image)
        #expect(Vignette.apply(VignetteAdjustments(amount: -20), to: image) !== image)
    }

    @Test("Darkening leaves the center alone and darkens the corners, keeping their color")
    func darkens() throws {
        let image = flat(red: 0.4, green: 0.2, blue: 0.1)
        let result = Vignette.apply(VignetteAdjustments(amount: -100), to: image)
        let center = try pixel(result, at: CGPoint(x: 300, y: 200))
        let corner = try pixel(result, at: CGPoint(x: 1, y: 1))
        #expect(abs(center.r - 0.4) < 0.002 && abs(center.g - 0.2) < 0.002)
        // Three stops at full strength.
        #expect(abs(corner.r - 0.05) < 0.003)
        #expect(abs(corner.r / corner.g - 2) < 0.05 && abs(corner.g / corner.b - 2) < 0.05)
    }

    @Test("Lightening brightens the corners without passing white")
    func lightens() throws {
        let result = Vignette.apply(VignetteAdjustments(amount: 100), to: gray(0.18))
        let corner = try pixel(result, at: CGPoint(x: 1, y: 1))
        #expect(corner.r > 0.6 && corner.r < 1)
        let white = try pixel(Vignette.apply(VignetteAdjustments(amount: 100), to: gray(1)), at: CGPoint(x: 1, y: 1))
        #expect(abs(white.r - 1) < 0.002)
    }

    @Test("Midpoint moves the effect toward the corners and Feather 0 makes a hard edge")
    func midpointAndFeather() throws {
        // A point two thirds of the way from the center to the right side.
        let point = CGPoint(x: 500, y: 200)
        let near = try pixel(Vignette.apply(VignetteAdjustments(amount: -100, midpoint: 0), to: gray(0.18)), at: point).r
        let far = try pixel(Vignette.apply(VignetteAdjustments(amount: -100, midpoint: 100), to: gray(0.18)), at: point).r
        #expect(near < far)
        #expect(abs(far - 0.18) < 0.002)
        // With no feather, the edge sits at the oval's midpoint, 0.8 of the way to each side.
        let hard = Vignette.apply(VignetteAdjustments(amount: -100, feather: 0), to: gray(0.18))
        #expect(abs(try pixel(hard, at: CGPoint(x: 300 + 300 * 0.75, y: 200)).r - 0.18) < 0.002)
        #expect(abs(try pixel(hard, at: CGPoint(x: 300 + 300 * 0.85, y: 200)).r - 0.0225) < 0.002)
    }

    @Test("Roundness 100 makes a circle and -100 reaches into the corners less")
    func roundness() throws {
        // On a 3:2 frame a circle darkens the middle of the long sides more than an oval does.
        let side = CGPoint(x: 590, y: 200)
        let oval = try pixel(Vignette.apply(VignetteAdjustments(amount: -100), to: gray(0.18)), at: side).r
        let circle = try pixel(Vignette.apply(VignetteAdjustments(amount: -100, roundness: 100), to: gray(0.18)), at: side).r
        #expect(circle < oval)
        // Squared off, it leaves more of a point partway to the corner.
        let diagonal = CGPoint(x: 300 + 300 * 0.7, y: 200 + 200 * 0.7)
        let rounded = try pixel(Vignette.apply(VignetteAdjustments(amount: -100), to: gray(0.18)), at: diagonal).r
        let squared = try pixel(Vignette.apply(VignetteAdjustments(amount: -100, roundness: -100), to: gray(0.18)), at: diagonal).r
        #expect(squared > rounded)
    }

    @Test("Values outside their ranges are clamped")
    func clampsValues() throws {
        let wild = Vignette.apply(VignetteAdjustments(amount: -400, midpoint: -20, roundness: 300, feather: 500), to: gray(0.18))
        let edge = Vignette.apply(VignetteAdjustments(amount: -100, midpoint: 0, roundness: 100, feather: 100), to: gray(0.18))
        for point in [CGPoint(x: 1, y: 1), CGPoint(x: 450, y: 250)] {
            #expect(abs(try pixel(wild, at: point).r - pixel(edge, at: point).r) < 0.0005)
        }
    }

    @Test("A smooth gray at full strength falls off in single 8-bit steps, without bands")
    func noBanding() throws {
        // A wide, sky-like frame, rendered to 8 bits for display as the canvas does.
        let rect = CGRect(x: 0, y: 0, width: 3000, height: 2000)
        let sky = CIImage(color: CIColor(red: 0.35, green: 0.5, blue: 0.8, colorSpace: linear)!).cropped(to: rect)
        for amount in [-100.0, 100] {
            let result = Vignette.apply(VignetteAdjustments(amount: amount, feather: 100), to: sky)
            let row = CGRect(x: 0, y: 1000, width: 1500, height: 1)
            var bytes = [UInt8](repeating: 0, count: 1500 * 4)
            context.render(result, toBitmap: &bytes, rowBytes: 1500 * 4, bounds: row, format: .RGBA8,
                           colorSpace: RAWRenderer.colorSpace)
            for channel in 0..<3 {
                let values = stride(from: channel, to: bytes.count, by: 4).map { Int(bytes[$0]) }
                let steps = zip(values, values.dropFirst()).map { $1 - $0 }
                // From the left edge toward the center the frame only brightens, or only darkens.
                #expect(steps.allSatisfy { amount < 0 ? $0 >= 0 : $0 <= 0 })
                #expect(steps.allSatisfy { abs($0) <= 1 })
            }
        }
    }

    @Test("The vignette centers on the cropped frame, and the thumbnail matches the canvas", .enabled(if: sampleDNG != nil))
    func followsCrop() async throws {
        let url = try #require(sampleDNG)
        var recipe = EditRecipe()
        // The left half of the photo, so the uncropped photo's center is the crop's right edge.
        recipe.crop = Crop(x: 0, y: 0, width: 0.5, height: 1)
        let renderer = try RAWRenderer()
        try await renderer.open(url)
        let plain = try image(of: await renderer.render(fitting: CGSize(width: 400, height: 400), recipe: recipe))
        recipe.vignette = VignetteAdjustments(amount: -100)
        let canvas = try image(of: await renderer.render(fitting: CGSize(width: 400, height: 400), recipe: recipe))
        let (w, h) = (canvas.extent.width, canvas.extent.height)
        func ratio(_ x: CGFloat, _ y: CGFloat) throws -> Double {
            let point = CGPoint(x: x, y: y)
            return try luminance(canvas, at: point) / max(luminance(plain, at: point), 1e-4)
        }
        // Untouched in the crop's middle; darkened the same on its left and right edges.
        #expect(abs(try ratio(w / 2, h / 2) - 1) < 0.02)
        let left = try ratio(2, h / 2), right = try ratio(w - 3, h / 2)
        #expect(left < 0.5 && right < 0.5)
        #expect(abs(left - right) < 0.05)

        let thumbnail = CIImage(cgImage: try await renderer.thumbnail(of: url, recipe: recipe, maxPixelSize: 400))
        #expect(thumbnail.extent.size == canvas.extent.size)
        #expect(abs(try mean(canvas) - mean(thumbnail)) < 0.01)
    }

    /// Renders comparison strips for issue #105: the original, then Amount -50, -100, +50 and +100,
    /// then -100 with Roundness 100, Feather 0 and Midpoint 0, for every RAW photo in
    /// `PROOF_COMPARE_DIR`. The PNGs go to `PROOF_COMPARE_OUTPUT`, or a temporary folder.
    @Test("Vignette comparison strips", .enabled(if: vignetteCompareFolder != nil))
    func comparisonStrips() async throws {
        let folder = try #require(vignetteCompareFolder)
        let output = ProcessInfo.processInfo.environment["PROOF_COMPARE_OUTPUT"].map(URL.init(fileURLWithPath:))
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("proof-compare")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let photos = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { ["dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let settings = [
            VignetteAdjustments(), VignetteAdjustments(amount: -50), VignetteAdjustments(amount: -100),
            VignetteAdjustments(amount: 50), VignetteAdjustments(amount: 100),
            VignetteAdjustments(amount: -100, roundness: 100), VignetteAdjustments(amount: -100, feather: 0),
            VignetteAdjustments(amount: -100, midpoint: 0),
        ]
        for photo in photos {
            let filter = try #require(CIRAWFilter(imageURL: photo))
            filter.scaleFactor = Float(RAWRenderer.scaleFactor(nativeSize: filter.nativeSize, orientation: filter.orientation,
                                                               fitting: CGSize(width: 480, height: 480)))
            let asShot = WhiteBalance(temperature: Double(filter.neutralTemperature), tint: Double(filter.neutralTint))
            let tiles = try settings.map { vignette in
                try #require(RAWRenderer.apply(EditRecipe(vignette: vignette), to: filter, asShot: asShot,
                                               cameraDetail: CameraDetail(of: filter)))
            }
            let strip = tiles.enumerated().reduce(CIImage.empty()) { strip, tile in
                let column = CGFloat(tile.offset % 4), row = CGFloat(1 - tile.offset / 4)
                return tile.element.transformed(by: CGAffineTransform(
                    translationX: column * (tile.element.extent.width + 16) - tile.element.extent.minX,
                    y: row * (tile.element.extent.height + 16) - tile.element.extent.minY))
                    .composited(over: strip)
            }
            let file = output.appendingPathComponent("\(photo.deletingPathExtension().lastPathComponent)-vignette.png")
            let background = CIImage(color: .white).cropped(to: strip.extent)
            try context.writePNGRepresentation(of: strip.composited(over: background), to: file,
                                               format: .RGBA8, colorSpace: RAWRenderer.colorSpace)
            print("Comparison strip: \(file.path)")
        }
    }

    /// A 600×400 frame of one linear gray, so its center is (300, 200).
    private func gray(_ value: CGFloat) -> CIImage {
        flat(red: value, green: value, blue: value)
    }

    private func flat(red: CGFloat, green: CGFloat, blue: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 600, height: 400))
    }

    /// The linear red, green and blue of the pixel at `point`.
    private func pixel(_ image: CIImage, at point: CGPoint) throws -> (r: Double, g: Double, b: Double) {
        var values = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &values, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: linear)
        return (Double(values[0]), Double(values[1]), Double(values[2]))
    }

    private func luminance(_ image: CIImage, at point: CGPoint) throws -> Double {
        let averaged = image.cropped(to: CGRect(x: point.x - 1, y: point.y - 1, width: 3, height: 3))
            .applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: CGRect(x: point.x - 1, y: point.y - 1, width: 3, height: 3))])
        let value = try pixel(averaged, at: .zero)
        return 0.2126 * value.r + 0.7152 * value.g + 0.0722 * value.b
    }

    private func mean(_ image: CIImage) throws -> Double {
        let averaged = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        let value = try pixel(averaged, at: .zero)
        return (value.r + value.g + value.b) / 3
    }

    private func image(of photo: RenderedPhoto) throws -> CIImage {
        try #require(CIImage(mtlTexture: photo.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
    }
}

let vignetteCompareFolder = ProcessInfo.processInfo.environment["PROOF_COMPARE_DIR"].map(URL.init(fileURLWithPath:))
