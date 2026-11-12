import CoreImage
import Testing
@testable import ProofKit

struct BlackAndWhiteTests {
    static let red: [Float] = [0.8, 0.1, 0.05]
    static let green: [Float] = [0.1, 0.7, 0.1]
    static let blue: [Float] = [0.05, 0.15, 0.8]

    @Test("Off passes the image through untouched, whatever the mix")
    func offSkipsStage() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(BlackAndWhiteStage.apply(BlackAndWhite(red: 50), to: image) === image)
        #expect(BlackAndWhiteStage.apply(BlackAndWhite(isOn: true), to: image) !== image)
    }

    @Test("At 0 the gray is the color's Rec. 709 luminance, the same in all three channels")
    func neutralMixIsLuminance() throws {
        for color in [Self.red, Self.green, Self.blue] {
            let gray = try render(color, BlackAndWhite(isOn: true))
            let luminance = 0.2126 * color[0] + 0.7152 * color[1] + 0.0722 * color[2]
            #expect(abs(gray[0] - luminance) < 1e-4)
            #expect(gray[0] == gray[1] && gray[1] == gray[2])
        }
    }

    @Test("The weights always add up to 1, so grays keep their brightness however the mix is set")
    func grayStaysGray() throws {
        for mix in [BlackAndWhite(isOn: true, red: 100), BlackAndWhite(isOn: true, red: -100, green: 60, blue: 100)] {
            let w = mix.weights
            #expect(abs(w.red + w.green + w.blue - 1) < 1e-12)
            #expect(abs(try render([0.4, 0.4, 0.4], mix)[0] - 0.4) < 1e-4)
        }
    }

    @Test("Raising a channel lightens colors that hold it and darkens the others, as a filter on film")
    func channelLightensItsColor() throws {
        let even = BlackAndWhite(isOn: true)
        let redFilter = BlackAndWhite(isOn: true, red: 80)
        #expect(try render(Self.red, redFilter)[0] > render(Self.red, even)[0] + 0.1)
        #expect(try render(Self.blue, redFilter)[0] < render(Self.blue, even)[0])
        let blueDown = BlackAndWhite(isOn: true, blue: -100)
        #expect(try render(Self.blue, blueDown)[0] < render(Self.blue, even)[0])
    }

    @Test("A channel at +100 alone makes the gray that channel, as a deep filter does")
    func fullFilterIsOneChannel() throws {
        let w = BlackAndWhite(isOn: true, red: 100).weights
        #expect(abs(w.red - 1) < 1e-12 && abs(w.green) < 1e-12 && abs(w.blue) < 1e-12)
        #expect(abs(try render(Self.blue, BlackAndWhite(isOn: true, red: 100))[0] - Self.blue[0]) < 1e-4)
    }

    @Test("A channel at -100 can darken its color past its darkest channel, but never below black")
    func negativeWeightsStopAtBlack() throws {
        let w = BlackAndWhite(isOn: true, red: -100).weights
        #expect(w.red < 0)
        #expect(try render(Self.red, BlackAndWhite(isOn: true, red: -100))[0] == 0)
        let muted: [Float] = [0.4, 0.1, 0.1]
        #expect(try render(muted, BlackAndWhite(isOn: true, red: -60))[0] < 0.1)
    }

    @Test("A filter sets the sliders, and a mix that matches one reads as it")
    func filters() throws {
        var mix = BlackAndWhite(isOn: true)
        #expect(mix.filter == BlackAndWhite.Filter.none)
        mix.choose(.red)
        #expect(mix.filter == .red && mix.red == 80 && mix.isOn)
        #expect(BlackAndWhite.Filter.allCases.map(\.title) == ["None", "Yellow", "Orange", "Red", "Green"])
        mix.blue += 1
        #expect(mix.filter == nil)
        // From Yellow to Red each darkens a blue sky more.
        let sky: [Float] = [0.1, 0.2, 0.4]
        var darkness: [Float] = []
        for filter in [BlackAndWhite.Filter.none, .yellow, .orange, .red] {
            var preset = BlackAndWhite(isOn: true)
            preset.choose(filter)
            darkness.append(try render(sky, preset)[0])
        }
        #expect(darkness == darkness.sorted(by: >) && Set(darkness).count == 4)
        var green = BlackAndWhite(isOn: true)
        green.choose(.green)
        #expect(try render(Self.green, green)[0] > render(Self.green, BlackAndWhite(isOn: true))[0])
    }

    @Test("Values outside -100 to 100 are clamped")
    func clampsValues() {
        let far = BlackAndWhite(isOn: true, red: 400).weights
        let edge = BlackAndWhite(isOn: true, red: 100).weights
        #expect(far == edge)
    }

    private func render(_ color: [Float], _ mix: BlackAndWhite) throws -> [Float] {
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let image = CIImage(color: CIColor(red: CGFloat(color[0]), green: CGFloat(color[1]), blue: CGFloat(color[2]),
                                           alpha: 1, colorSpace: space)!).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1))
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        context.render(BlackAndWhiteStage.apply(mix, to: image), toBitmap: &pixel,
                       rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return pixel
    }
}
