import CoreImage

/// One of the eight hue ranges that Selective Color adjusts. Each is named for the hue at its center.
public enum ColorRange: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, aqua, blue, purple, magenta

    /// The range's center, in degrees around the HSV hue circle of display-encoded color.
    /// Warm hues sit closer together than cool ones, as in Lightroom's ranges, because the eye
    /// tells them apart over a smaller turn of the circle.
    public var hue: Double {
        switch self {
        case .red: 0
        case .orange: 30
        case .yellow: 60
        case .green: 120
        case .aqua: 180
        case .blue: 225
        case .purple: 270
        case .magenta: 315
        }
    }

    public var title: String { rawValue.capitalized }

    /// The ranges on either side, around the circle.
    public var previous: ColorRange {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + all.count - 1) % all.count]
    }

    public var next: ColorRange {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// Degrees from this range's center to its neighbor's, always positive.
    var degreesToPrevious: Double { (hue - previous.hue + 360).truncatingRemainder(dividingBy: 360) }
    var degreesToNext: Double { (next.hue - hue + 360).truncatingRemainder(dividingBy: 360) }

    /// The range a hue in degrees falls in: the one whose center is nearest.
    public static func containing(hue: Double) -> ColorRange {
        let hue = (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        return allCases.min { distance($0.hue, hue) < distance($1.hue, hue) }!
    }

    private static func distance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b)
        return min(d, 360 - d)
    }
}

/// One color range's Hue, Saturation and Brightness, each from −100 to 100.
public struct ColorRangeAdjustment: Codable, Equatable, Sendable {
    /// Turns the range's colors toward the previous range (negative) or the next (positive);
    /// ±100 reaches the neighbor's center.
    public var hue: Double = 0
    /// Mutes (negative) or intensifies (positive) the range's colors; −100 leaves them gray.
    public var saturation: Double = 0
    /// Darkens (negative) or lightens (positive) the range's colors.
    public var brightness: Double = 0

    public static let range = -100.0...100.0

    private enum CodingKeys: String, CodingKey {
        case hue, saturation, brightness
    }

    public init(hue: Double = 0, saturation: Double = 0, brightness: Double = 0) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hue = try c.decodeIfPresent(Double.self, forKey: .hue) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        brightness = try c.decodeIfPresent(Double.self, forKey: .brightness) ?? 0
    }

    public var isNeutral: Bool { self == ColorRangeAdjustment() }
}

/// The Selective Color card's values: an adjustment for each color range. Saved as an object
/// keyed by range name; a missing range is unadjusted.
public struct SelectiveColor: Codable, Equatable, Sendable {
    private var adjustments: [ColorRange: ColorRangeAdjustment] = [:]

    public init() {}

    public subscript(range: ColorRange) -> ColorRangeAdjustment {
        get { adjustments[range] ?? ColorRangeAdjustment() }
        set { adjustments[range] = newValue.isNeutral ? nil : newValue }
    }

    public var isNeutral: Bool { adjustments.isEmpty }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: ColorRange.self)
        for range in ColorRange.allCases {
            if let adjustment = try c.decodeIfPresent(ColorRangeAdjustment.self, forKey: range) {
                self[range] = adjustment
            }
        }
    }

    /// Writes all eight ranges, so the file reads the same whichever were changed.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: ColorRange.self)
        for range in ColorRange.allCases { try c.encode(self[range], forKey: range) }
    }
}

extension ColorRange: CodingKey {}

/// Applies Selective Color in linear light, after Vibrance and Saturation and before the look.
/// See docs/decisions/0026-selective-color.md.
enum SelectiveColorStage {
    /// Brightness ±100 scales a range's colors by this many stops.
    static let brightnessStops = 1.5

    /// Each pixel's hue, in display-encoded HSV, picks its weight in the two ranges whose centers
    /// it lies between, easing from one to the other, so no edge shows between ranges. The
    /// effect fades out toward gray, which has no hue to adjust. Values outside −100…100, which
    /// only a hand-edited sidecar can hold, are clamped. A neutral `selectiveColor` returns the
    /// image as is.
    static func apply(_ selectiveColor: SelectiveColor, to image: CIImage) -> CIImage {
        guard !selectiveColor.isNeutral, let kernel else { return image }
        var hue = [Float](), saturation = [Float](), stops = [Float]()
        for range in ColorRange.allCases {
            let adjustment = selectiveColor[range]
            let h = clamped(adjustment.hue) / 100
            hue.append(Float(h * (h < 0 ? range.degreesToPrevious : range.degreesToNext)))
            saturation.append(Float(clamped(adjustment.saturation) / 100))
            stops.append(Float(clamped(adjustment.brightness) / 100 * brightnessStops))
        }
        func vectors(_ values: [Float]) -> [CIVector] {
            [CIVector(x: CGFloat(values[0]), y: CGFloat(values[1]), z: CGFloat(values[2]), w: CGFloat(values[3])),
             CIVector(x: CGFloat(values[4]), y: CGFloat(values[5]), z: CGFloat(values[6]), w: CGFloat(values[7]))]
        }
        return kernel.apply(extent: image.extent, arguments: [image] + vectors(hue) + vectors(saturation) + vectors(stops))
            ?? image
    }

    static func clamped(_ value: Double) -> Double {
        min(max(value, ColorRangeAdjustment.range.lowerBound), ColorRangeAdjustment.range.upperBound)
    }

    /// Compiled once. `nil` only on a GPU that can't compile Metal at run time, where the card
    /// then has no effect rather than failing the whole render.
    private static let kernel: CIColorKernel? = {
        let compiled = try? CIKernel.kernels(withMetalString: source)
        return compiled?.first { $0.name == "proofSelectiveColor" } as? CIColorKernel
    }()

    /// The range centers must match `ColorRange.hue`, with red repeated at 360 to close the
    /// circle. Hue and saturation change in display-encoded HSV (a 2.2 gamma is close enough to
    /// find hues); brightness is a gain in linear light, so it keeps each color's hue and
    /// saturation. Lightening eases the brightest channel toward 1, as the vignette's does, so
    /// bright colors don't clip. Negative channels, out of gamut, are left in the result as they came in.
    private static let source = """
    #include <CoreImage/CoreImage.h>
    using namespace metal;

    extern "C" {
    namespace coreimage {
        [[stitchable]] float4 proofSelectiveColor(sample_t pixel, float4 hueA, float4 hueB, float4 satA, float4 satB,
                                                  float4 stopsA, float4 stopsB) {
            const float centers[9] = { 0.0, 30.0, 60.0, 120.0, 180.0, 225.0, 270.0, 315.0, 360.0 };
            float hues[8] = { hueA.x, hueA.y, hueA.z, hueA.w, hueB.x, hueB.y, hueB.z, hueB.w };
            float sats[8] = { satA.x, satA.y, satA.z, satA.w, satB.x, satB.y, satB.z, satB.w };
            float stops[8] = { stopsA.x, stopsA.y, stopsA.z, stopsA.w, stopsB.x, stopsB.y, stopsB.z, stopsB.w };

            float3 linear = pixel.rgb;
            float3 below = min(linear, 0.0);
            float3 e = pow(max(linear, 0.0), float3(1.0 / 2.2));
            float v = max(e.r, max(e.g, e.b));
            float c = v - min(e.r, min(e.g, e.b));
            if (v <= 0.0 || c <= 0.0) { return pixel; }
            float s = c / v;
            float h;
            if (v == e.r) { h = fmod((e.g - e.b) / c + 6.0, 6.0); }
            else if (v == e.g) { h = (e.b - e.r) / c + 2.0; }
            else { h = (e.r - e.g) / c + 4.0; }
            h *= 60.0;

            int i = 0;
            for (int k = 1; k < 8; k++) { if (h >= centers[k]) { i = k; } }
            int j = (i + 1) % 8;
            float t = smoothstep(0.0, 1.0, (h - centers[i]) / (centers[i + 1] - centers[i]));
            // Near-grays have an unsteady hue; fading in over the lowest saturations keeps
            // noise in them from being colored.
            float strength = smoothstep(0.02, 0.2, s);
            float dHue = mix(hues[i], hues[j], t) * strength;
            float dSat = mix(sats[i], sats[j], t) * strength;
            float dStops = mix(stops[i], stops[j], t) * strength;

            float h2 = fmod(h + dHue + 360.0, 360.0) / 60.0;
            float s2 = clamp(s * (1.0 + dSat), 0.0, 1.0);
            float3 k3 = fmod(float3(5.0, 3.0, 1.0) + h2, 6.0);
            float3 rgb = v - v * s2 * clamp(min(k3, 4.0 - k3), 0.0, 1.0);
            float3 result = pow(rgb, float3(2.2));

            float gain = exp2(dStops);
            if (dStops < 0.0) {
                result *= gain;
            } else if (dStops > 0.0) {
                // Eased on the brightest channel and applied to all three alike, so the color
                // keeps its hue as it nears white.
                float m = max(result.r, max(result.g, result.b));
                if (m > 0.0 && m < 1.0) { result *= gain / (1.0 + (gain - 1.0) * m); }
            }
            return float4(result + below, pixel.a);
        }
    }
    }
    """
}
