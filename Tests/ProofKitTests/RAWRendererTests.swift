import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct RAWRendererTests {
    private let m11 = CGSize(width: 9504, height: 6320)

    @Test("A landscape photo is scaled down to fit the window")
    func fitsLandscape() {
        let scale = RAWRenderer.scaleFactor(nativeSize: m11, orientation: .up, fitting: CGSize(width: 1900, height: 2000))
        #expect(abs(scale - 0.2) < 0.0001)
    }

    @Test("A portrait photo fits by its rotated size")
    func fitsPortrait() {
        let scale = RAWRenderer.scaleFactor(nativeSize: m11, orientation: .right, fitting: CGSize(width: 2000, height: 1900.8))
        #expect(abs(scale - 0.2) < 0.0001)
    }

    @Test("A photo is never rendered larger than the sensor")
    func neverUpscales() {
        let scale = RAWRenderer.scaleFactor(nativeSize: m11, orientation: .up, fitting: CGSize(width: 20_000, height: 20_000))
        #expect(scale == 1)
    }

    @Test("Opening a file that isn't a RAW photo fails")
    func rejectsNonRAW() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-photo.dng")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let renderer = try RAWRenderer()
        await #expect(throws: RAWRendererError.unsupportedFile(url)) {
            try await renderer.open(url)
        }
    }

    @Test("Rendering before opening a photo fails")
    func requiresOpenPhoto() async throws {
        let renderer = try RAWRenderer()
        await #expect(throws: RAWRendererError.noPhotoOpen) {
            _ = try await renderer.render(fitting: CGSize(width: 100, height: 100))
        }
    }

    /// RAW files can't be committed, so this runs only when `PROOF_SAMPLE_DNG` names one, e.g.
    /// `PROOF_SAMPLE_DNG=~/Pictures/L1000725.DNG swift test`. Set `PROOF_RENDER_OUTPUT` to a
    /// .png path to also save the render for a visual check.
    @Test("A real RAW photo renders at the requested size", .enabled(if: sampleDNG != nil))
    func rendersSample() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let target = CGSize(width: 1600, height: 1000)
        let photo = try await renderer.render(fitting: target)

        let size = CGSize(width: photo.texture.width, height: photo.texture.height)
        #expect(size.width <= target.width + 1 && size.height <= target.height + 1)
        #expect(size.width >= target.width - 1 || size.height >= target.height - 1)

        if let output = ProcessInfo.processInfo.environment["PROOF_RENDER_OUTPUT"] {
            let image = try #require(CIImage(mtlTexture: photo.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
            try CIContext().writePNGRepresentation(of: image, to: URL(fileURLWithPath: output),
                                                   format: .RGBA8, colorSpace: RAWRenderer.colorSpace)
        }
    }

    @Test("Raising exposure brightens a real RAW photo", .enabled(if: sampleDNG != nil))
    func exposureBrightens() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let target = CGSize(width: 400, height: 400)
        let base = try averageLuminance(await renderer.render(fitting: target))
        let brighter = try averageLuminance(await renderer.render(fitting: target, recipe: .exposure(1)))
        let darker = try averageLuminance(await renderer.render(fitting: target, recipe: .exposure(-1)))
        #expect(brighter > base)
        #expect(darker < base)
    }

    /// Renders served from the cached RAW decode must match an uncached first render exactly,
    /// or caching would change how saved edits look.
    @Test("Returning to an exposure renders the same pixels as a fresh renderer", .enabled(if: sampleDNG != nil))
    func cachedRenderMatchesFresh() async throws {
        let url = try #require(sampleDNG)
        let target = CGSize(width: 400, height: 400)

        let fresh = try RAWRenderer()
        try await fresh.open(url)
        let expected = try pixels(await fresh.render(fitting: target, recipe: .exposure(1)))

        let reused = try RAWRenderer()
        try await reused.open(url)
        for exposure in [0.0, 1, -1] {
            _ = try await reused.render(fitting: target, recipe: .exposure(exposure))
        }
        let actual = try pixels(await reused.render(fitting: target, recipe: .exposure(1)))
        #expect(actual == expected)
    }

    @Test("A higher temperature warms a real RAW photo and a positive tint adds magenta", .enabled(if: sampleDNG != nil))
    func whiteBalanceShiftsColor() async throws {
        let url = try #require(sampleDNG)
        let renderer = try RAWRenderer()
        try await renderer.open(url)
        let target = CGSize(width: 400, height: 400)
        func average(temperature: Double, tint: Double) async throws -> [Float] {
            var recipe = EditRecipe()
            recipe.basic.setTemperature(temperature)
            recipe.basic.setTint(tint)
            return try averageColor(await renderer.render(fitting: target, recipe: recipe))
        }
        let cool = try await average(temperature: 3000, tint: 0)
        let warm = try await average(temperature: 9000, tint: 0)
        #expect(warm[0] / warm[2] > cool[0] / cool[2])
        let green = try await average(temperature: 5500, tint: -50)
        let magenta = try await average(temperature: 5500, tint: 50)
        #expect(magenta[1] < green[1])
    }

    /// The renderer reuses one filter, so after a white balance change As Shot has to put the
    /// camera's values back rather than keep the last ones.
    @Test("Returning to As Shot renders the same pixels as a fresh renderer", .enabled(if: sampleDNG != nil))
    func asShotAfterChangeMatchesFresh() async throws {
        let url = try #require(sampleDNG)
        let target = CGSize(width: 400, height: 400)

        let fresh = try RAWRenderer()
        try await fresh.open(url)
        let expected = try pixels(await fresh.render(fitting: target))

        let reused = try RAWRenderer()
        try await reused.open(url)
        var tungsten = EditRecipe()
        tungsten.basic.choose(.tungsten)
        _ = try await reused.render(fitting: target, recipe: tungsten)
        let actual = try pixels(await reused.render(fitting: target))
        #expect(actual == expected)
    }

    /// Records how long an exposure change takes to render, for issue #3. Each size is warmed up
    /// once, then timed over several exposure values; the median is printed.
    @Test("Exposure render timings at full resolution and a quarter", .enabled(if: sampleDNG != nil))
    func exposureTimings() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        for scale in [1.0, 0.25] {
            _ = try await renderer.render(scaleFactor: scale, recipe: EditRecipe())
            var times: [Double] = []
            var size = ""
            for exposure in [0.5, -0.5, 1, -1, 1.5, -1.5, 2] {
                let start = ContinuousClock.now
                let photo = try await renderer.render(scaleFactor: scale, recipe: .exposure(exposure))
                times.append((ContinuousClock.now - start) / .milliseconds(1))
                size = "\(photo.texture.width)×\(photo.texture.height)"
            }
            times.sort()
            let median = times[times.count / 2]
            print("Exposure render at scaleFactor \(scale) (\(size)): median \(String(format: "%.1f", median)) ms, "
                + "range \(String(format: "%.1f", times.first!))–\(String(format: "%.1f", times.last!)) ms")
        }
    }

    /// Records how long an exposure change takes at window sizes, to decide whether a slider
    /// drag needs a reduced preview. Each size is warmed up once; the median is printed.
    @Test("Exposure render timings at window sizes", .enabled(if: sampleDNG != nil))
    func windowTimings() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        for target in [CGSize(width: 1600, height: 1000), CGSize(width: 2880, height: 1800), CGSize(width: 3456, height: 2234)] {
            _ = try await renderer.render(fitting: target)
            var times: [Double] = []
            var size = ""
            for exposure in [0.5, -0.5, 1, -1, 1.5, -1.5, 2, 0.25, -0.25] {
                let start = ContinuousClock.now
                let photo = try await renderer.render(fitting: target, recipe: .exposure(exposure))
                times.append((ContinuousClock.now - start) / .milliseconds(1))
                size = "\(photo.texture.width)×\(photo.texture.height)"
            }
            times.sort()
            print("Window render fitting \(Int(target.width))×\(Int(target.height)) (\(size)): median "
                + "\(String(format: "%.1f", times[times.count / 2])) ms, "
                + "range \(String(format: "%.1f", times.first!))–\(String(format: "%.1f", times.last!)) ms")
        }
    }

    /// 100% must show one photo pixel per screen pixel: a region rendered at full resolution has
    /// the region's size in pixels and the same pixels as that part of the whole photo.
    @Test("A region at 100% has the same pixels as that part of the full-resolution photo", .enabled(if: sampleDNG != nil))
    func regionMatchesFullResolution() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let recipe = EditRecipe.exposure(0.5)
        let full = try await renderer.render(scaleFactor: 1, recipe: recipe)
        let size = full.photoSize
        #expect(size == CGSize(width: full.texture.width, height: full.texture.height))

        let pixelRect = CGRect(x: 3001, y: 2003, width: 400, height: 300)
        let region = CGRect(x: pixelRect.minX / size.width, y: pixelRect.minY / size.height,
                            width: pixelRect.width / size.width, height: pixelRect.height / size.height)
        let part = try await renderer.render(region: region, scale: 1, recipe: recipe)
        #expect(part.texture.width == 400 && part.texture.height == 300)
        #expect(abs(part.region.minX * size.width - pixelRect.minX) < 0.001)
        #expect(abs(part.region.minY * size.height - pixelRect.minY) < 0.001)

        // Both bitmaps hold the top row first.
        let wholePixels = try pixels(full)
        let partPixels = try pixels(part)
        var largest = 0
        for row in 0..<300 {
            for column in 0..<400 {
                let a = ((Int(pixelRect.minY) + row) * full.texture.width + Int(pixelRect.minX) + column) * 4
                let b = (row * 400 + column) * 4
                for channel in 0..<3 { largest = max(largest, abs(Int(wholePixels[a + channel]) - Int(partPixels[b + channel]))) }
            }
        }
        #expect(largest <= 1)
    }

    /// Records how long panning at 100% takes to sharpen on a Retina window: region renders of
    /// the view alone and with the canvas's margin, moved across the photo as a drag would, then
    /// an exposure change on one region, as a slider drag while zoomed would.
    @Test("Region render timings while panning at 100%", .enabled(if: sampleDNG != nil))
    func panTimings() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let view = CGSize(width: 2560, height: 1600)
        let size = try await renderer.render(fitting: view).photoSize
        for margin in [0.0, 0.25] {
            var times: [Double] = []
            var rendered = ""
            for step in 0..<12 {
                let viewport = Viewport(scale: 1, center: CGPoint(x: 0.2 + Double(step) * 0.05, y: 0.3 + Double(step) * 0.03))
                    .clamped(photo: size, view: view)
                let visible = viewport.visibleRegion(photo: size, view: view)
                let region = visible.insetBy(dx: -visible.width * margin, dy: -visible.height * margin)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let start = ContinuousClock.now
                let photo = try await renderer.render(region: region, scale: 1)
                times.append((ContinuousClock.now - start) / .milliseconds(1))
                rendered = "\(photo.texture.width)×\(photo.texture.height)"
            }
            report("Panned region render at 100% (\(rendered))", times)
        }
        let region = CGRect(x: 0.3, y: 0.3, width: view.width / size.width, height: view.height / size.height)
        _ = try await renderer.render(region: region, scale: 1)
        var times: [Double] = []
        for exposure in [0.5, -0.5, 1, -1, 1.5, -1.5, 2] {
            let start = ContinuousClock.now
            _ = try await renderer.render(region: region, scale: 1, recipe: .exposure(exposure))
            times.append((ContinuousClock.now - start) / .milliseconds(1))
        }
        report("Exposure change on one region at 100%", times)
    }

    private func report(_ label: String, _ times: [Double]) {
        let sorted = times.sorted()
        print("\(label): median \(String(format: "%.1f", sorted[sorted.count / 2])) ms, "
            + "range \(String(format: "%.1f", sorted.first!))–\(String(format: "%.1f", sorted.last!)) ms")
    }

    private func pixels(_ photo: RenderedPhoto) throws -> [UInt8] {
        let image = try #require(CIImage(mtlTexture: photo.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
        let rowBytes = photo.texture.width * 4
        var bytes = [UInt8](repeating: 0, count: rowBytes * photo.texture.height)
        CIContext().render(image, toBitmap: &bytes, rowBytes: rowBytes, bounds: image.extent,
                           format: .RGBA8, colorSpace: RAWRenderer.colorSpace)
        return bytes
    }

    private func averageLuminance(_ photo: RenderedPhoto) throws -> Double {
        let pixel = try averageColor(photo)
        return Double(0.2126 * pixel[0] + 0.7152 * pixel[1] + 0.0722 * pixel[2])
    }

    @Test("A placeholder fills the frame of the photo it stands in for, not its own shape")
    func placeholderTakesPhotoSize() throws {
        let context = try #require(CGContext(data: nil, width: 512, height: 300, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let image = try #require(context.makeImage())
        let renderer = try RAWRenderer()
        let placeholder = try renderer.placeholder(image, photoSize: m11)
        #expect(placeholder.texture.width == 512 && placeholder.texture.height == 300)
        #expect(placeholder.photoSize == m11)
        #expect(placeholder.region == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("A file that isn't a RAW photo has no photo size")
    func noPhotoSizeForNonRAW() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-photo-\(UUID().uuidString).dng")
        try Data("hello".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(RAWRenderer.photoSize(of: url, crop: nil) == nil)
    }

    @Test("The photo size read ahead of a render matches the render's, with and without a crop",
          .enabled(if: sampleDNG != nil))
    func photoSizeMatchesRender() async throws {
        let url = try #require(sampleDNG)
        let renderer = try RAWRenderer()
        try await renderer.open(url)
        var cropped = EditRecipe()
        cropped.crop = Crop(x: 0.1, y: 0.2, width: 0.5, height: 0.6, rotation: 90)
        for recipe in [EditRecipe(), cropped] {
            let photo = try await renderer.render(fitting: CGSize(width: 800, height: 800), recipe: recipe)
            #expect(RAWRenderer.photoSize(of: url, crop: recipe.crop) == photo.photoSize)
        }
    }

    /// The photo's average red, green, blue and alpha.
    private func averageColor(_ photo: RenderedPhoto) throws -> [Float] {
        let image = try #require(CIImage(mtlTexture: photo.texture, options: [.colorSpace: RAWRenderer.colorSpace]))
        let average = image.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: image.extent)])
        var pixel = [Float](repeating: 0, count: 4)
        CIContext().render(average, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBAf, colorSpace: RAWRenderer.colorSpace)
        return pixel
    }
}

let sampleDNG = ProcessInfo.processInfo.environment["PROOF_SAMPLE_DNG"].map(URL.init(fileURLWithPath:))

extension EditRecipe {
    static func exposure(_ stops: Double) -> EditRecipe {
        var recipe = EditRecipe()
        recipe.basic.exposure = stops
        return recipe
    }
}
