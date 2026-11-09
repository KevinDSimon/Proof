import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct HistogramTests {
    private let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf,
    ])

    private func solid(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, in rect: CGRect) -> CIImage {
        CIImage(color: CIColor(red: red, green: green, blue: blue, colorSpace: displayP3)!).cropped(to: rect)
    }

    private func peak(_ bins: [Float]) -> Int {
        bins.indices.max { bins[$0] < bins[$1] }!
    }

    @Test("Each channel is counted at its encoded level, not in linear light")
    func countsEncodedValues() throws {
        let image = solid(1, 0.5, 0, in: CGRect(x: 0, y: 0, width: 64, height: 64))
        let histogram = try #require(Histogram.measure(image, colorSpace: displayP3, context: context))

        #expect(peak(histogram.red) == 255)
        #expect((127...128).contains(peak(histogram.green)))
        #expect(peak(histogram.blue) == 0)
        #expect(abs(histogram.red[255] - 1) < 0.001)
    }

    @Test("Bins hold the fraction of pixels at each level and add up to 1")
    func binsAreFractions() throws {
        let black = solid(0, 0, 0, in: CGRect(x: 0, y: 0, width: 30, height: 40))
        let white = solid(1, 1, 1, in: CGRect(x: 30, y: 0, width: 10, height: 40))
        let histogram = try #require(Histogram.measure(white.composited(over: black), colorSpace: displayP3, context: context))

        for channel in [histogram.red, histogram.green, histogram.blue] {
            #expect(channel.count == Histogram.binCount)
            #expect(abs(channel.reduce(0, +) - 1) < 0.001)
            #expect(abs(channel[0] - 0.75) < 0.001)
            #expect(abs(channel[255] - 0.25) < 0.001)
        }
    }

    @Test("A real photo's histogram is measured from its screen-size render", .enabled(if: sampleDNG != nil))
    func measuresSample() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let photo = try await renderer.render(fitting: CGSize(width: 2560, height: 1600))
        _ = try renderer.histogram(of: photo)

        let clock = ContinuousClock()
        var histogram: Histogram?
        var times: [Duration] = []
        for _ in 0..<7 {
            times.append(try clock.measure { histogram = try renderer.histogram(of: photo) })
        }
        let median = times.sorted()[times.count / 2]
        let measured = try #require(histogram)
        #expect(abs(measured.green.reduce(0, +) - 1) < 0.001)
        // It runs beside the render loop, not in it, but should still keep up with a slider drag:
        // inside one 30 fps frame, the bar renders are held to. Alone it takes about 6 ms on an M2;
        // other suites rendering on the GPU at the same time can more than double that.
        #expect(median < .milliseconds(33), "Histogram median \(median), all \(times)")
    }
}
