import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct ToneLookupTests {
    /// Every slider alone at each end, and all three together.
    static let extremes: [(contrast: Double, whites: Double, blacks: Double)] = [
        (100, 0, 0), (-100, 0, 0), (0, 100, 0), (0, -100, 0), (0, 0, 100), (0, 0, -100),
        (100, 100, -100), (-100, -100, 100), (100, 100, 100), (-100, -100, -100),
    ]

    @Test("Values outside -100 to 100 are clamped")
    func clampsValues() {
        #expect(ToneLookup(contrast: 250, whites: -180, blacks: 30) == ToneLookup(contrast: 100, whites: -100, blacks: 30))
    }

    @Test("With all three sliders at 0 the stage passes the image through untouched")
    func neutralSkipsStage() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64))
        #expect(ToneLookup(contrast: 0, whites: 0, blacks: 0).apply(to: image) === image)
        #expect(ToneLookup(contrast: 20, whites: 0, blacks: 0).apply(to: image) !== image)
        let neutral = ToneLookup(contrast: 0, whites: 0, blacks: 0)
        for i in 0...100 {
            let v = Double(i) / 100
            #expect(abs(neutral.curve(v) - v) < 1e-12)
        }
    }

    @Test("Black and white stay in place at every setting")
    func endsStayFixed() {
        for s in Self.extremes {
            let lookup = ToneLookup(contrast: s.contrast, whites: s.whites, blacks: s.blacks)
            #expect(abs(lookup.curve(0)) < 1e-12)
            #expect(abs(lookup.curve(1) - 1) < 1e-12)
        }
    }

    @Test("The curve always rises, even with every slider at an end")
    func alwaysRises() {
        for s in Self.extremes {
            let table = ToneLookup(contrast: s.contrast, whites: s.whites, blacks: s.blacks).table()
            for i in 1..<ToneLookup.count {
                #expect(table[i * 4] > table[(i - 1) * 4], "\(s) at entry \(i)")
            }
        }
    }

    @Test("Contrast leaves middle gray in place, darkens below it and brightens above it")
    func contrastPivotsOnMiddleGray() {
        let more = ToneLookup(contrast: 100, whites: 0, blacks: 0)
        let less = ToneLookup(contrast: -100, whites: 0, blacks: 0)
        for lookup in [more, less] {
            #expect(abs(lookup.curve(ToneLookup.pivot) - ToneLookup.pivot) < 1e-12)
        }
        #expect(more.curve(0.25) < 0.25 && more.curve(0.75) > 0.75)
        #expect(less.curve(0.25) > 0.25 && less.curve(0.75) < 0.75)
    }

    @Test("Whites moves the bright tones and Blacks the dark ones")
    func whitesAndBlacksMoveTheirEnds() {
        let whites = ToneLookup(contrast: 0, whites: 100, blacks: 0)
        #expect(whites.curve(0.75) > 0.8)
        #expect(abs(whites.curve(0.1) - 0.1) < 0.001)
        let blacks = ToneLookup(contrast: 0, whites: 0, blacks: -100)
        #expect(blacks.curve(0.25) < 0.2)
        #expect(abs(blacks.curve(0.9) - 0.9) < 0.001)
    }

    /// A float ramp from a little below black to above white, in even sRGB-encoded steps, through
    /// the GPU kernel in 32-bit float. The output must match the CPU, never fall, and never jump
    /// by more than twice the step the curve calls for: a jump is a band.
    @Test("A smooth gradient comes out smooth, matching the CPU, at every slider's ends")
    func noBanding() throws {
        let count = 8192
        let encoded = (0..<count).map { -0.05 + 1.2 * Float($0) / Float(count - 1) }
        let ramp = encoded.map(ToneLookup.decode)
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let pixels: [Float] = ramp.flatMap { [$0, $0, $0, 1] }
        let input = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) },
                            bytesPerRow: count * 16, size: CGSize(width: count, height: 1), format: .RGBAf, colorSpace: linear)
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])

        for s in Self.extremes {
            let lookup = ToneLookup(contrast: s.contrast, whites: s.whites, blacks: s.blacks)
            var output = [Float](repeating: 0, count: count * 4)
            context.render(lookup.apply(to: input), toBitmap: &output, rowBytes: count * 16, bounds: input.extent,
                           format: .RGBAf, colorSpace: linear)
            let table = lookup.table(), slopes = lookup.endSlopes(channel: 0)
            let expected = ramp.map { ToneLookup.evaluate($0, table: table, channel: 0, endSlopes: slopes) }

            var largestDifference: Float = 0, falls = 0, jumps = 0
            for i in 0..<count {
                for channel in 0..<3 { largestDifference = max(largestDifference, abs(output[i * 4 + channel] - expected[i])) }
                guard i > 0 else { continue }
                let step = output[i * 4] - output[(i - 1) * 4]
                if step < 0 { falls += 1 }
                if step > 2 * (expected[i] - expected[i - 1]) + 1e-6 { jumps += 1 }
            }
            #expect(largestDifference <= 1e-4, "\(s): GPU and CPU differ by \(largestDifference)")
            #expect(falls == 0, "\(s): output falls \(falls) times")
            #expect(jumps == 0, "\(s): output jumps \(jumps) times")
        }
    }

    @Test("The lookup matches the curve it samples")
    func tableMatchesCurve() {
        let lookup = ToneLookup(contrast: 60, whites: -40, blacks: 30)
        let table = lookup.table(), slopes = lookup.endSlopes(channel: 0)
        for i in 0...1000 {
            let v = Double(i) / 1000
            let looked = ToneLookup.encode(Double(ToneLookup.evaluate(ToneLookup.decode(Float(v)), table: table, channel: 0, endSlopes: slopes)))
            #expect(abs(looked - lookup.curve(v)) < 1e-5)
        }
    }
}
