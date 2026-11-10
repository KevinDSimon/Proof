import CoreImage
import Foundation

/// The Contrast, Whites and Blacks sliders and the tone curve, baked into one lookup per channel
/// and applied by a small kernel. The sliders come first, then the RGB curve, then each
/// channel's own curve.
///
/// The lookup is indexed by sRGB-encoded values, which spread its entries evenly across what
/// the eye sees as dark to light. Inside 0…1 the sliders keep black and white in place; outside,
/// where an extended-range decode can reach, it continues in a straight line instead of clipping.
struct ToneLookup: Equatable {
    static let range: ClosedRange<Double> = -100...100
    static let count = 4096

    /// Middle gray, 0.18 in linear light, sRGB-encoded. Contrast turns around this value.
    static let pivot = encode(0.18)
    /// Contrast at ±100 doubles or halves the curve's slope at middle gray.
    static let contrastStops = 1.0
    /// Each from -1 to 1.
    let contrast: Double, whites: Double, blacks: Double
    /// The RGB curve, then the red, green and blue curves.
    let rgb: CurveSpline, red: CurveSpline, green: CurveSpline, blue: CurveSpline

    init(contrast: Double, whites: Double, blacks: Double, curve: ToneCurve = ToneCurve()) {
        self.contrast = Self.clamped(contrast) / 100
        self.whites = Self.clamped(whites) / 100
        self.blacks = Self.clamped(blacks) / 100
        rgb = CurveSpline(curve.rgb)
        red = CurveSpline(curve.red)
        green = CurveSpline(curve.green)
        blue = CurveSpline(curve.blue)
    }

    var isNeutral: Bool {
        contrast == 0 && whites == 0 && blacks == 0
            && rgb.isIdentity && red.isIdentity && green.isIdentity && blue.isIdentity
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    /// The whole lookup for one channel (0 red, 1 green, 2 blue) on sRGB-encoded values from 0
    /// to 1.
    func output(_ v: Double, channel: Int) -> Double {
        let toned = rgb(curve(v))
        switch channel {
        case 0: return red(toned)
        case 1: return green(toned)
        default: return blue(toned)
        }
    }

    /// The sliders' part of the lookup: Whites and Blacks first, then Contrast.
    func curve(_ v: Double) -> Double {
        let lifted = v + Self.bumps(v, whites: whites, blacks: blacks)
        return Self.contrast(min(max(lifted, 0), 1), gain: exp2(contrast * Self.contrastStops))
    }

    /// Whites raises or lowers tones toward the bright end, Blacks toward the dark end. Each bump
    /// is zero at both ends, so black and white stay where they are, and peaks three quarters of
    /// the way toward its end. At ±100 a bump's steepest fall is 0.9, at its end, so the curve's
    /// slope never drops below 0.1. Whites flattens only the bright end and Blacks only the dark
    /// end, so the two never add up to a flatter curve.
    private static func bumps(_ v: Double, whites: Double, blacks: Double) -> Double {
        func shape(_ x: Double) -> Double { 0.9 * x * x * x * (1 - x) }
        return whites * shape(v) + blacks * shape(1 - v)
    }

    /// Steepens the curve at the pivot by `gain` and flattens it toward the ends by the same
    /// factor. A rational curve rather than a power curve, whose slope at black would be
    /// infinite or zero and band in the lookup.
    private static func contrast(_ v: Double, gain: Double) -> Double {
        func half(_ x: Double) -> Double { x / (gain - (gain - 1) * x) }
        if v <= pivot { return pivot * half(v / pivot) }
        return 1 - (1 - pivot) * half((1 - v) / (1 - pivot))
    }

    /// The lookup sampled at `count` evenly spaced encoded values, as red, green, blue and an
    /// unused fourth channel, ready to upload as a one-row float image.
    func table() -> [Float] {
        var values = [Float](repeating: 0, count: Self.count * 4)
        for i in 0..<Self.count {
            let toned = rgb(curve(Double(i) / Double(Self.count - 1)))
            values[i * 4] = Float(red(toned))
            values[i * 4 + 1] = Float(green(toned))
            values[i * 4 + 2] = Float(blue(toned))
        }
        return values
    }

    /// One channel's slope at black and at white, which the straight continuations outside 0…1
    /// follow.
    func endSlopes(channel: Int) -> (low: Double, high: Double) {
        let h = 1e-6
        return ((output(h, channel: channel) - output(0, channel: channel)) / h,
                (output(1, channel: channel) - output(1 - h, channel: channel)) / h)
    }

    /// What the kernel does to one channel, on the CPU: the reference the GPU result is tested
    /// against.
    static func evaluate(_ linear: Float, table: [Float], channel: Int, endSlopes: (low: Double, high: Double)) -> Float {
        let e = encode(linear)
        let last = count - 1
        let first = table[channel], end = table[last * 4 + channel]
        let out: Float
        if e < 0 {
            out = first + e * Float(endSlopes.low)
        } else if e > 1 {
            out = end + (e - 1) * Float(endSlopes.high)
        } else {
            let position = e * Float(last)
            let index = min(Int(position), last - 1)
            let fraction = position - Float(index)
            let a = table[index * 4 + channel], b = table[(index + 1) * 4 + channel]
            out = a + (b - a) * fraction
        }
        return decode(out)
    }

    /// Applies the lookup to `image`, which is in linear light. With the sliders at 0 and the
    /// curves straight the image is returned as is.
    func apply(to image: CIImage) -> CIImage {
        guard !isNeutral, let kernel = Self.kernel else { return image }
        let values = table()
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        // No color space: the values are curve outputs, not colors, and must reach the kernel as is.
        let lookup = CIImage(bitmapData: data, bytesPerRow: Self.count * 16,
                             size: CGSize(width: Self.count, height: 1), format: .RGBAf, colorSpace: nil)
            .samplingNearest()
        let (r, g, b) = (endSlopes(channel: 0), endSlopes(channel: 1), endSlopes(channel: 2))
        let lookupExtent = lookup.extent
        return kernel.apply(extent: image.extent, roiCallback: { index, rect in
            index == 0 ? rect : lookupExtent
        }, arguments: [
            image, lookup,
            CIVector(x: r.low, y: g.low, z: b.low),
            CIVector(x: r.high, y: g.high, z: b.high),
        ]) ?? image
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the
    /// sliders then have no effect rather than failing the whole render.
    private static let kernel: CIKernel? = {
        guard let compiled = try? CIKernel.kernels(withMetalString: source) else { return nil }
        return compiled.first { $0.name == "proofToneLookup" }
    }()

    // sRGB's transfer function, extended to negative values by mirroring.
    static func encode(_ x: Double) -> Double {
        let a = abs(x)
        let e = a <= 0.0031308 ? 12.92 * a : 1.055 * pow(a, 1 / 2.4) - 0.055
        return x < 0 ? -e : e
    }

    static func encode(_ x: Float) -> Float { Float(encode(Double(x))) }

    static func decode(_ e: Float) -> Float {
        let a = abs(Double(e))
        let x = a <= 0.04045 ? a / 12.92 : pow((a + 0.055) / 1.055, 2.4)
        return Float(e < 0 ? -x : x)
    }

    /// The lookup is read with nearest sampling at entry centers and interpolated here, in
    /// 32-bit float: some GPUs filter textures at about 8-bit precision, which bands.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    namespace proof {
        constant float last = 4095.0;

        inline float encode(float x) {
            float a = fabs(x);
            float e = a <= 0.0031308 ? 12.92 * a : 1.055 * precise::pow(a, 1.0 / 2.4) - 0.055;
            return copysign(e, x);
        }

        inline float decode(float e) {
            float a = fabs(e);
            float x = a <= 0.04045 ? a / 12.92 : precise::pow((a + 0.055) / 1.055, 2.4);
            return copysign(x, e);
        }

        inline float4 entry(coreimage::sampler table, float index) {
            return table.sample(table.transform(float2(index + 0.5, 0.5)));
        }

        inline float lookup(coreimage::sampler table, float linear, int channel, float lowSlope, float highSlope) {
            float e = encode(linear);
            float out;
            if (e < 0.0) {
                out = entry(table, 0.0)[channel] + e * lowSlope;
            } else if (e > 1.0) {
                out = entry(table, last)[channel] + (e - 1.0) * highSlope;
            } else {
                float position = e * last;
                float index = min(floor(position), last - 1.0);
                float fraction = position - index;
                out = mix(entry(table, index)[channel], entry(table, index + 1.0)[channel], fraction);
            }
            return decode(out);
        }
    }

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofToneLookup(sampler image, sampler table, float3 lowSlope, float3 highSlope, destination dest) {
            float4 pixel = image.sample(image.coord());
            return float4(proof::lookup(table, pixel.r, 0, lowSlope.r, highSlope.r),
                          proof::lookup(table, pixel.g, 1, lowSlope.g, highSlope.g),
                          proof::lookup(table, pixel.b, 2, lowSlope.b, highSlope.b),
                          pixel.a);
        }
    }
    }
    """
}
