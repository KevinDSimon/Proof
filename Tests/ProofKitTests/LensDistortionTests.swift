import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct LensDistortionTests {
    static let width = 600, height = 400
    static let spacing = 50.0

    /// Dark lines every `spacing` pixels each way on a light ground, with soft edges so their
    /// centers can be found to a fraction of a pixel.
    static func grid(_ x: Double, _ y: Double) -> Float {
        func distance(_ v: Double) -> Double { abs(v - (v / spacing).rounded() * spacing) }
        let d = min(distance(x - Double(width) / 2), distance(y - Double(height) / 2))
        return Float(0.8 - 0.6 * exp(-d * d / (2 * 1.5 * 1.5)))
    }

    /// The grid as a lens with this much distortion would draw it: each pixel shows the point the
    /// correction reads it from, found by inverting the correction's radius.
    static func distorted(by distortion: Double) -> [Float] {
        let k = LensDistortion.strength(distortion)
        let scale = LensDistortion.fillScale(strength: k, size: CGSize(width: width, height: height))
        let cx = Double(width) / 2, cy = Double(height) / 2
        let radius = (cx * cx + cy * cy).squareRoot()
        var pixels: [Float] = []
        for row in 0..<height {
            for column in 0..<width {
                // Core Image's origin is at the bottom left, so the row counts up from there.
                let dx = Double(column) + 0.5 - cx, dy = Double(height - 1 - row) + 0.5 - cy
                let read = (dx * dx + dy * dy).squareRoot() / radius
                var r = read
                for _ in 0..<20 { r -= (r * scale * (1 + k * r * r) - read) / (scale * (1 + 3 * k * r * r)) }
                let f = read > 0 ? r / read : 1
                let value = grid(cx + dx * f, cy + dy * f)
                pixels += [value, value, value, 1]
            }
        }
        return pixels
    }

    static func image(_ pixels: [Float]) -> CIImage {
        CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                size: CGSize(width: width, height: height), format: .RGBAf,
                colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }

    static func render(_ image: CIImage) -> [Float] {
        var bitmap = [Float](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
            .render(image, toBitmap: &bitmap, rowBytes: width * 16,
                    bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: space)
        return bitmap
    }

    /// How far, at most, the center of the vertical line nearest the left edge strays from a
    /// straight line, measured row by row away from the top and bottom edges and from the rows where a
    /// horizontal line crosses it and hides it.
    static func bend(of pixels: [Float]) -> Double {
        let line = Double(width) / 2 - 5 * spacing - 0.5
        var centers: [Double] = []
        for row in 20..<(height - 20) {
            var weight = 0.0, total = 0.0
            let first = Int(line) - 15, last = Int(line) + 15
            if min(pixels[(row * width + first) * 4], pixels[(row * width + last) * 4]) < 0.79 { continue }
            for column in first...last {
                let darkness = Double(0.8 - pixels[(row * width + column) * 4])
                weight += darkness
                total += darkness * Double(column)
            }
            centers.append(total / weight)
        }
        return (centers.max() ?? 0) - (centers.min() ?? 0)
    }

    @Test("A grid drawn with barrel or pincushion distortion comes out straight at the matching setting")
    func straightensLines() {
        for distortion in [30.0, -30.0] {
            let drawn = Self.distorted(by: distortion)
            #expect(Self.bend(of: drawn) > 3)
            let corrected = Self.render(LensDistortion.apply(distortion, to: Self.image(drawn)))
            #expect(Self.bend(of: corrected) < 0.25)
        }
    }

    @Test("The corrected photo fills the frame and keeps as much of it as it can")
    func fillsFrame() {
        let size = CGSize(width: 3, height: 2)
        let diagonal = (size.width * size.width + size.height * size.height).squareRoot()
        for distortion in [-100.0, -30.0, 30.0, 100.0] {
            let k = LensDistortion.strength(distortion)
            let scale = LensDistortion.fillScale(strength: k, size: size)
            // How far past the photo's edge each point along the frame's edge reads, as a
            // fraction: never above 0, and 0 somewhere, or the photo could be kept larger.
            var furthest = -Double.infinity
            for i in 0...200 {
                let t = Double(i) / 200
                for (x, y) in [(t * size.width, 0.0), (t * size.width, size.height), (0, t * size.height), (size.width, t * size.height)] {
                    let dx = x - size.width / 2, dy = y - size.height / 2
                    let f = scale * (1 + k * (dx * dx + dy * dy) / (diagonal * diagonal / 4))
                    furthest = max(furthest, abs(dx * f) / (size.width / 2) - 1, abs(dy * f) / (size.height / 2) - 1)
                }
            }
            #expect(furthest <= 1e-9)
            #expect(furthest > -1e-3)
        }
        #expect(LensDistortion.fillScale(strength: 0, size: size) == 1)
    }

    @Test("Positive Distortion corrects barrel distortion, and the correction keeps the photo's size")
    func direction() throws {
        #expect(LensDistortion.strength(50) < 0)
        #expect(LensDistortion.strength(-50) > 0)
        #expect(LensDistortion.strength(500) == LensDistortion.strength(100))
        let image = Self.image(Self.distorted(by: 0))
        #expect(LensDistortion.apply(nil, to: image) === image)
        #expect(LensDistortion.apply(0, to: image) === image)
        #expect(LensDistortion.apply(40, to: image).extent == image.extent)
    }
}
