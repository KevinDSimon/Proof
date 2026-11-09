import CoreImage
import Testing
@testable import ProofKit

struct ColorAdjustmentsTests {
    @Test("Values outside -100 to 100 are clamped")
    func clampsValues() {
        #expect(ColorAdjustments.clamped(250) == 100)
        #expect(ColorAdjustments.clamped(-180) == -100)
        #expect(ColorAdjustments.clamped(30) == 30)
    }

    @Test("With both sliders at 0 the stage passes the image through untouched")
    func neutralSkipsStage() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(ColorAdjustments.apply(to: image, vibrance: 0, saturation: 0) === image)
        #expect(ColorAdjustments.apply(to: image, vibrance: 20, saturation: 0) !== image)
        #expect(ColorAdjustments.apply(to: image, vibrance: 0, saturation: 20) !== image)
    }

    @Test("Saturation -100 makes every color gray")
    func saturationRemovesColor() throws {
        for color in [CIColor(red: 0.8, green: 0.1, blue: 0.05), CIColor(red: 0.1, green: 0.6, blue: 0.9), CIColor(red: 1.4, green: 0.3, blue: 0.2)] {
            let pixel = try render(color, vibrance: 0, saturation: -100)
            #expect(abs(pixel[0] - pixel[1]) < 1e-3 && abs(pixel[1] - pixel[2]) < 1e-3)
        }
    }

    @Test("Saturation raises and lowers color without changing a gray")
    func saturationMovesBothWays() throws {
        let color = CIColor(red: 0.5, green: 0.3, blue: 0.2)
        let original = chroma(try render(color, vibrance: 0, saturation: 0))
        #expect(chroma(try render(color, vibrance: 0, saturation: 50)) > original)
        #expect(chroma(try render(color, vibrance: 0, saturation: -50)) < original)
        let gray = try render(CIColor(red: 0.3, green: 0.3, blue: 0.3), vibrance: 0, saturation: 80)
        for channel in 0..<3 { #expect(abs(gray[channel] - 0.3) < 1e-3) }
    }

    @Test("Vibrance raises muted colors more than vivid ones and leaves grays alone")
    func vibranceFavorsMutedColors() throws {
        let muted = CIColor(red: 0.4, green: 0.35, blue: 0.3)
        let vivid = CIColor(red: 0.8, green: 0.1, blue: 0.05)
        func gain(_ color: CIColor) throws -> Float {
            chroma(try render(color, vibrance: 100, saturation: 0)) / chroma(try render(color, vibrance: 0, saturation: 0))
        }
        let mutedGain = try gain(muted), vividGain = try gain(vivid)
        #expect(mutedGain > 1)
        #expect(mutedGain > vividGain)
        #expect(chroma(try render(muted, vibrance: -100, saturation: 0)) < chroma(try render(muted, vibrance: 0, saturation: 0)))
        let gray = try render(CIColor(red: 0.3, green: 0.3, blue: 0.3), vibrance: 100, saturation: 0)
        for channel in 0..<3 { #expect(abs(gray[channel] - 0.3) < 1e-3) }
    }

    /// How far a color is from gray, relative to its brightest channel.
    private func chroma(_ pixel: [Float]) -> Float {
        let rgb = pixel.prefix(3)
        return (rgb.max()! - rgb.min()!) / rgb.max()!
    }

    private func render(_ color: CIColor, vibrance: Double, saturation: Double) throws -> [Float] {
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let image = CIImage(color: CIColor(red: color.red, green: color.green, blue: color.blue, alpha: 1, colorSpace: space)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        context.render(ColorAdjustments.apply(to: image, vibrance: vibrance, saturation: saturation), toBitmap: &pixel,
                       rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return pixel
    }
}
