import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct LensVignettingTests {
    static let width = 600, height = 400

    /// A flat mid gray, corrected by `vignetting` and rendered as floats in linear light.
    static func corrected(_ vignetting: LensVignetting) -> [Float] {
        let flat = CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1,
                                         colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!)!)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        var bitmap = [Float](repeating: 0, count: width * height * 4)
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
            .render(LensVignetting.apply(vignetting, to: flat), toBitmap: &bitmap, rowBytes: width * 16,
                    bounds: flat.extent, format: .RGBAf, colorSpace: space)
        return bitmap
    }

    /// Green along the diagonal from the center to the top right corner.
    static func diagonal(of pixels: [Float]) -> [Float] {
        (0..<200).map { i in
            let column = width / 2 + i * (width / 2 - 1) / 199, row = height / 2 - 1 - i * (height / 2 - 1) / 199
            return pixels[(row * width + column) * 4 + 1]
        }
    }

    @Test("Positive Amount brightens the corners and negative darkens them, leaving the center alone")
    func brightensAndDarkens() {
        let brighter = Self.diagonal(of: Self.corrected(LensVignetting(amount: 50)))
        #expect(abs(brighter[0] - 0.18) < 0.001)
        // One stop at the corners at Amount 50.
        #expect(abs(brighter[199] / 0.18 - 2) < 0.03)
        let darker = Self.diagonal(of: Self.corrected(LensVignetting(amount: -50)))
        #expect(abs(darker[199] / 0.18 - 0.5) < 0.01)
    }

    @Test("The correction grows smoothly toward the corners, without steps, even as 8-bit output")
    func noBanding() {
        // Every pixel along a row matches the smooth falloff, so there is no step to see.
        let vignetting = LensVignetting(amount: 100)
        let pixels = Self.corrected(vignetting)
        let row = Self.height / 4
        let cx = Double(Self.width) / 2, cy = Double(Self.height) / 2
        let radius = (cx * cx + cy * cy).squareRoot()
        for column in 0..<Self.width {
            let dx = Double(column) + 0.5 - cx, dy = Double(Self.height - 1 - row) + 0.5 - cy
            let expected = 0.18 * exp2(vignetting.stops(at: (dx * dx + dy * dy).squareRoot() / radius))
            #expect(abs(Double(pixels[(row * Self.width + column) * 4 + 1]) / expected - 1) < 0.002)
        }

        // Neighboring pixels along a row differ by at most one 8-bit level.
        func encoded(_ v: Float) -> Int {
            let c = min(max(v, 0), 1)
            return Int(((c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255).rounded())
        }
        let levels = (0..<Self.width).map { encoded(pixels[(row * Self.width + $0) * 4 + 1]) }
        #expect(zip(levels.dropFirst(), levels).allSatisfy { abs($0 - $1) <= 1 })
    }

    @Test("A higher Midpoint keeps the correction closer to the corners")
    func midpoint() {
        let near = LensVignetting(amount: 100, midpoint: 80), far = LensVignetting(amount: 100, midpoint: 20)
        #expect(near.stops(at: 0.6) < far.stops(at: 0.6))
        #expect(abs(near.stops(at: 1) - far.stops(at: 1)) < 1e-9)
        #expect(LensVignetting(amount: 0).stops(at: 1) == 0)
    }
}
