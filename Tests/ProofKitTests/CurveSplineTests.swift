import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct CurveSplineTests {
    static let sCurve = [CurvePoint(0, 0), CurvePoint(0.25, 0.18), CurvePoint(0.75, 0.84), CurvePoint(1, 1)]

    @Test("The default curve is a straight line")
    func identity() {
        let spline = CurveSpline(ToneCurve.identity)
        #expect(spline.isIdentity)
        #expect(ToneCurve().isIdentity)
        for i in 0...100 {
            let v = Double(i) / 100
            #expect(abs(spline(v) - v) < 1e-12)
        }
    }

    @Test("The curve passes through every point")
    func passesThroughPoints() {
        let spline = CurveSpline(Self.sCurve)
        for point in Self.sCurve { #expect(abs(spline(point.input) - point.output) < 1e-12) }
    }

    @Test("Between two points the curve stays between their outputs, even when points are close")
    func neverOvershoots() {
        let points = [CurvePoint(0, 0), CurvePoint(0.3, 0.1), CurvePoint(0.32, 0.6), CurvePoint(0.6, 0.62),
                      CurvePoint(0.62, 0.3), CurvePoint(1, 1)]
        let spline = CurveSpline(points)
        for (a, b) in zip(points, points.dropFirst()) {
            let low = min(a.output, b.output), high = max(a.output, b.output)
            for i in 0...200 {
                let y = spline(a.input + (b.input - a.input) * Double(i) / 200)
                #expect(y >= low - 1e-12 && y <= high + 1e-12)
            }
        }
    }

    @Test("A curve through rising points never falls")
    func monotone() {
        let spline = CurveSpline(Self.sCurve + [CurvePoint(0.5, 0.52), CurvePoint(0.52, 0.53)])
        var previous = spline(0)
        for i in 1...2000 {
            let y = spline(Double(i) / 2000)
            #expect(y >= previous - 1e-12)
            previous = y
        }
    }

    @Test("Moving an end point inward clips: the curve is flat beyond it")
    func flatBeyondEnds() {
        let spline = CurveSpline([CurvePoint(0.1, 0.05), CurvePoint(0.9, 0.95)])
        #expect(spline(0) == 0.05 && spline(0.05) == 0.05)
        #expect(spline(1) == 0.95 && spline(0.95) == 0.95)
    }

    @Test("Unsorted, out-of-range and repeated points from a hand-edited sidecar still give a curve")
    func sanitizesPoints() {
        let messy = CurveSpline([CurvePoint(1.4, 1), CurvePoint(0.5, 0.6), CurvePoint(-0.2, 0), CurvePoint(0.5, 0.2)])
        #expect(messy == CurveSpline([CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]))
        #expect(CurveSpline([CurvePoint(0.5, 0.5)]).isIdentity)
        #expect(CurveSpline([]).isIdentity)
        #expect(CurveSpline([CurvePoint(.nan, 0.3), CurvePoint(1, 1)]) == CurveSpline([CurvePoint(0, 0.3), CurvePoint(1, 1)]))
    }

    @Test("A curve on the RGB channel moves all three channels; a red curve moves only red")
    func channels() {
        var curve = ToneCurve()
        curve.rgb = Self.sCurve
        let rgb = ToneLookup(contrast: 0, whites: 0, blacks: 0, curve: curve)
        #expect(!rgb.isNeutral)
        for channel in 0..<3 { #expect(rgb.output(0.25, channel: channel) < 0.2) }

        curve = ToneCurve()
        curve.red = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        let red = ToneLookup(contrast: 0, whites: 0, blacks: 0, curve: curve)
        #expect(red.output(0.5, channel: 0) > 0.59)
        #expect(abs(red.output(0.5, channel: 1) - 0.5) < 1e-12)
        #expect(abs(red.output(0.5, channel: 2) - 0.5) < 1e-12)
    }

    @Test("The RGB curve follows the sliders, and each channel's curve follows the RGB curve")
    func order() {
        var curve = ToneCurve()
        curve.rgb = Self.sCurve
        curve.blue = [CurvePoint(0, 0.1), CurvePoint(1, 0.9)]
        let lookup = ToneLookup(contrast: 40, whites: 0, blacks: 0, curve: curve)
        let rgb = CurveSpline(curve.rgb), blue = CurveSpline(curve.blue)
        for v in [0.1, 0.4, 0.8] {
            #expect(abs(lookup.output(v, channel: 2) - blue(rgb(lookup.curve(v)))) < 1e-12)
        }
    }

    @Test("Default levels change nothing; black and white clip, and the midtone lands on middle gray")
    func levels() {
        #expect(LevelsMap(Levels()).isIdentity)
        let map = LevelsMap(Levels(black: 0.1, midtone: 0.3, white: 0.8))
        #expect(map(0.05) == 0 && map(0.1) == 0)
        #expect(map(0.85) == 1 && map(0.8) == 1)
        #expect(abs(map(0.1 + 0.3 * 0.7) - 0.5) < 1e-12)
        // A midtone left of center brightens.
        #expect(map(0.45) > (0.45 - 0.1) / 0.7)
        for y in [0.0, 0.2, 0.5, 0.9, 1.0] { #expect(abs(map(map.inverse(y)) - y) < 1e-12) }
    }

    @Test("Handles from a hand-edited sidecar are kept in order and the midtone off the ends")
    func sanitizesLevels() {
        let crossed = LevelsMap(Levels(black: 0.9, midtone: 1.4, white: 0.3))
        #expect(crossed.white - crossed.black >= LevelsMap.minimumGap - 1e-12)
        #expect(crossed.midtone == LevelsMap.midtoneRange.upperBound)
        #expect(LevelsMap(Levels(black: .nan, midtone: .infinity, white: -1)).black == 0)
    }

    @Test("A channel's levels apply before its points")
    func levelsBeforePoints() {
        var curve = ToneCurve()
        curve.rgb = Self.sCurve
        curve[levels: .rgb] = Levels(black: 0.05, midtone: 0.45, white: 0.9)
        #expect(!curve.isIdentity(.rgb))
        let lookup = ToneLookup(contrast: 0, whites: 0, blacks: 0, curve: curve)
        let expected = CurveSpline(Self.sCurve)(LevelsMap(curve.levels.rgb)(0.4))
        for channel in 0..<3 { #expect(abs(lookup.output(0.4, channel: channel) - expected) < 1e-12) }
    }

    /// The GPU kernel against the CPU with a different curve on each channel, so a channel mixed
    /// up in the kernel or in its end slopes shows.
    @Test("Each channel's curve renders on the GPU as on the CPU")
    func gpuMatchesCPU() {
        var curve = ToneCurve()
        curve.rgb = Self.sCurve
        curve.red = [CurvePoint(0, 0.05), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        curve.green = [CurvePoint(0, 0), CurvePoint(0.4, 0.35), CurvePoint(0.9, 1)]
        curve.blue = [CurvePoint(0.1, 0), CurvePoint(1, 0.9)]
        curve[levels: .green] = Levels(black: 0.05, midtone: 0.4, white: 0.95)
        let lookup = ToneLookup(contrast: 20, whites: 0, blacks: 0, curve: curve)

        let count = 4096
        let ramp = (0..<count).map { ToneLookup.decode(-0.05 + 1.2 * Float($0) / Float(count - 1)) }
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let pixels: [Float] = ramp.flatMap { [$0, $0, $0, 1] }
        let input = CIImage(bitmapData: pixels.withUnsafeBufferPointer { Data(buffer: $0) },
                            bytesPerRow: count * 16, size: CGSize(width: count, height: 1), format: .RGBAf, colorSpace: linear)
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf, .cacheIntermediates: false])
        var output = [Float](repeating: 0, count: count * 4)
        context.render(lookup.apply(to: input), toBitmap: &output, rowBytes: count * 16, bounds: input.extent,
                       format: .RGBAf, colorSpace: linear)

        let table = lookup.table()
        for channel in 0..<3 {
            let slopes = lookup.endSlopes(channel: channel)
            var largest: Float = 0
            for i in 0..<count {
                let expected = ToneLookup.evaluate(ramp[i], table: table, channel: channel, endSlopes: slopes)
                largest = max(largest, abs(output[i * 4 + channel] - expected))
            }
            #expect(largest <= 1e-4, "channel \(channel): GPU and CPU differ by \(largest)")
        }
    }
}
