import Foundation
import simd

/// Auto white balance and Auto for the Tone sliders. `CIRAWFilter` has no automatic setting for
/// RAW files, so both are estimated from a small render of the photo and written to the edit as
/// ordinary values, which render the same in every later version. See
/// docs/decisions/0018-auto-adjust.md for the method.
public enum AutoAdjust {
    /// Long edge, in pixels, of the render the estimates are made from.
    static let sampleSize: CGFloat = 256

    // MARK: White balance

    /// How far a white balance is from neutral, in stops: blue against red (positive is too
    /// blue), and green against the other two (positive is too green). Both 0 when neutral.
    struct Cast: Equatable {
        var blueYellow: Double
        var greenMagenta: Double

        var size: Double { max(abs(blueYellow), abs(greenMagenta)) }
    }

    /// The color of the light in `pixels`, linear RGB, as a cast. A weighted gray world: pixels
    /// near gray count more than colorful ones, which are more likely the color of a surface
    /// than of the light, and each channel is a 4-norm mean, which leans toward bright pixels
    /// (shades of gray). The darkest 5% are left out as noise, and so are the brightest 2% and
    /// any pixel with a channel near clipping, whose color the sensor no longer records.
    /// `nil` when too few pixels are left to judge.
    static func cast(of pixels: [SIMD3<Float>]) -> Cast? {
        let lit = pixels.filter { $0.min() > 0 }
        guard lit.count >= 16 else { return nil }
        let luminance = lit.map(Self.luminance).sorted()
        let low = percentile(0.05, of: luminance), high = percentile(0.98, of: luminance)
        let clip = percentile(0.999, of: lit.map { $0.max() }.sorted()) * 0.97

        var sum = SIMD3<Double>(repeating: 0), weights = 0.0, count = 0
        for pixel in lit {
            let y = Self.luminance(pixel)
            guard y >= low, y <= high, pixel.max() < clip else { continue }
            let p = SIMD3<Double>(pixel)
            let chroma = (p.max() - p.min()) / p.max()
            let weight = 1 / (1 + 8 * chroma)
            sum += weight * p * p * p * p
            weights += weight
            count += 1
        }
        guard count >= 16, weights > 0 else { return nil }
        let mean = sum / weights
        let r = pow(mean.x, 0.25), g = pow(mean.y, 0.25), b = pow(mean.z, 0.25)
        return Cast(blueYellow: log2(b / r), greenMagenta: log2(g / (r * b).squareRoot()))
    }

    /// Pixels across the patch the eyedropper measures.
    static let patchSize: CGFloat = 8

    /// The cast of a patch picked as neutral gray: the color of its plain mean, linear RGB.
    /// `nil` when the patch is too dark for its color to show through the noise.
    static func cast(ofNeutral pixels: [SIMD3<Float>]) -> Cast? {
        guard !pixels.isEmpty else { return nil }
        let mean = SIMD3<Double>(pixels.reduce(SIMD3<Float>(repeating: 0), +)) / Double(pixels.count)
        guard mean.max() > 0.002, mean.min() > 0 else { return nil }
        return Cast(blueYellow: log2(mean.z / mean.x), greenMagenta: log2(mean.y / (mean.x * mean.z).squareRoot()))
    }

    /// The white balance that leaves no cast, found by Newton's method on the temperature (in
    /// mireds, where equal steps look alike) and the tint. `measure` renders the photo with a
    /// white balance and returns its cast. The first step is judged from two small nudges;
    /// later steps refine that judgment from how the last step turned out (Broyden's method).
    /// Stops once the cast is under 0.01 stops or after `maxSteps`; the result is within the
    /// sliders' ranges and rounded to 10 K and a whole tint.
    static func whiteBalance(from start: WhiteBalance, maxSteps: Int = 6,
                             measure: (WhiteBalance) throws -> Cast?) rethrows -> WhiteBalance? {
        func point(_ wb: WhiteBalance) -> SIMD2<Double> { [1e6 / wb.temperature, wb.tint] }
        func balance(_ x: SIMD2<Double>) -> WhiteBalance {
            let mireds = 1e6 / WhiteBalance.temperatureRange.upperBound...1e6 / WhiteBalance.temperatureRange.lowerBound
            return WhiteBalance(temperature: 1e6 / min(max(x.x, mireds.lowerBound), mireds.upperBound),
                                tint: min(max(x.y, WhiteBalance.tintRange.lowerBound), WhiteBalance.tintRange.upperBound))
        }
        func vector(_ cast: Cast) -> SIMD2<Double> { [cast.blueYellow, cast.greenMagenta] }

        var x = point(balance(point(start)))
        guard let first = try measure(balance(x)) else { return nil }
        var f = vector(first)
        if first.size >= 0.01 {
            // The two nudges: 10 mireds warmer and 5 toward magenta.
            let nudge = SIMD2<Double>(10, 5)
            guard let byTemperature = try measure(balance(x + [nudge.x, 0])),
                  let byTint = try measure(balance(x + [0, nudge.y]))
            else { return nil }
            var jacobian = simd_double2x2(columns: ((vector(byTemperature) - f) / nudge.x,
                                                   (vector(byTint) - f) / nudge.y))
            for _ in 0..<maxSteps {
                guard abs(jacobian.determinant) > 1e-12 else { break }
                let step = -(jacobian.inverse * f)
                let next = point(balance(x + step))
                guard let cast = try measure(balance(next)) else { break }
                let nextF = vector(cast), moved = next - x
                if simd_length_squared(moved) > 1e-12 {
                    // Broyden's update: the smallest change to the judgment that explains this step.
                    let change = (nextF - f) - jacobian * moved
                    let scale = 1 / simd_length_squared(moved)
                    jacobian = jacobian + simd_double2x2(columns: (change * (moved.x * scale), change * (moved.y * scale)))
                }
                x = next
                f = nextF
                if cast.size < 0.01 { break }
            }
        }
        let result = balance(x)
        return WhiteBalance(temperature: (result.temperature / 10).rounded() * 10, tint: result.tint.rounded())
    }

    // MARK: Tone

    /// The six Tone sliders as Auto sets them.
    public struct Tone: Equatable, Sendable {
        public var exposure: Double
        public var contrast: Double
        public var highlights: Double
        public var shadows: Double
        public var whites: Double
        public var blacks: Double

        public init(exposure: Double = 0, contrast: Double = 0, highlights: Double = 0,
                    shadows: Double = 0, whites: Double = 0, blacks: Double = 0) {
            self.exposure = exposure
            self.contrast = contrast
            self.highlights = highlights
            self.shadows = shadows
            self.whites = whites
            self.blacks = blacks
        }

        /// Sets the Tone sliders of `basic` to these values.
        public func apply(to basic: inout BasicAdjustments) {
            basic.exposure = exposure
            basic.contrast = contrast
            basic.highlights = highlights
            basic.shadows = shadows
            basic.whites = whites
            basic.blacks = blacks
        }
    }

    /// Middle gray in linear light, where exposure aims the photo's average brightness.
    static let middleGray = 0.18

    /// The Tone sliders for `luminances`, the linear brightness of each pixel rendered with all
    /// six at 0. Exposure brings the photo's log average, its brightness as the eye weighs it, to
    /// middle gray, unless that would push the brightest areas close to white. The other sliders then each answer one measurement of the exposed photo:
    /// Highlights pulls back a top 1% that would clip, Shadows lifts a darkest 10% that is
    /// nearly black, Whites and Blacks stretch the ends to white and black when the photo
    /// doesn't reach them, and Contrast moves the spread of the middle 80% toward 5.5 stops.
    /// Each is limited so Auto stays a starting point rather than a strong look.
    static func tone(luminances: [Float]) -> Tone {
        let sorted = luminances.map { Double(max($0, 0)) }.sorted()
        guard sorted.count >= 16, let top = sorted.last, top > 0 else { return Tone() }

        // The log average of the middle 98%, so a few black or blown pixels don't swing it.
        let low = percentile(0.01, of: sorted), high = percentile(0.99, of: sorted)
        let middle = sorted.filter { $0 >= low && $0 <= high }
        let floor = 1e-4
        let logAverage = exp(middle.map { log(max($0, floor)) }.reduce(0, +) / Double(max(middle.count, 1)))
        let toMiddleGray = clamp(log2(middleGray / max(logAverage, floor)), -3...3)
        // Brightening stops where the brightest 2% would reach 0.9, so a bright sky over a dark
        // foreground isn't pushed to white, but it gives up at most 1.5 stops for that and
        // leaves the rest to Highlights.
        let headroom = log2(0.9 / max(percentile(0.98, of: sorted), floor))
        let exposure = clamp(max(min(toMiddleGray, headroom), toMiddleGray - 1.5), -3...3)
        let gain = pow(2, exposure)
        func exposed(_ q: Double) -> Double { percentile(q, of: sorted) * gain }

        // Above 0.8, the top 1% starts to lose its detail on the way to white.
        let p99 = exposed(0.99)
        let highlights = p99 > 0.8 ? -clamp(45 * log2(p99 / 0.8), 0...70) : 0
        // Below 0.03, about 2.5 stops under middle gray, the darkest 10% is close to black.
        let p10 = exposed(0.10)
        let shadows = p10 < 0.03 ? clamp(25 * log2(0.03 / max(p10, floor)), 0...60) : 0
        // A brightest pixel well short of white leaves the photo looking dull.
        let p999 = exposed(0.999)
        let whites = p999 < 0.7 ? clamp(40 * log2(0.7 / max(p999, floor)), 0...40) : 0
        // A darkest pixel well above black leaves the photo looking hazy.
        let p001 = exposed(0.001)
        let blacks = p001 > 0.004 ? -clamp(15 * log2(p001 / 0.004), 0...40) : 0
        // Flat photos get more contrast and contrasty ones less.
        let spread = log2(max(exposed(0.9), floor) / max(exposed(0.1), floor))
        let contrast = clamp(8 * (5.5 - spread), -20...30)

        return Tone(exposure: (exposure * 20).rounded() / 20, contrast: contrast.rounded(),
                     highlights: highlights.rounded(), shadows: shadows.rounded(),
                     whites: whites.rounded(), blacks: blacks.rounded())
    }

    // MARK: Helpers

    static func luminance(_ pixel: SIMD3<Float>) -> Float {
        0.2126 * pixel.x + 0.7152 * pixel.y + 0.0722 * pixel.z
    }

    /// The value at `q`, from 0 to 1, of `sorted`, which must not be empty.
    static func percentile<T>(_ q: Double, of sorted: [T]) -> T {
        sorted[min(max(Int((Double(sorted.count - 1) * q).rounded()), 0), sorted.count - 1)]
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
