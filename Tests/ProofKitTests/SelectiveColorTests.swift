import CoreImage
import Testing
@testable import ProofKit

struct SelectiveColorTests {
    /// Linear colors whose 2.2-gamma HSV hue is at a range's center: orange at 30°, green at 120°.
    static let orange = linear(1, 0.5, 0)
    static let green = linear(0.2, 0.9, 0.2)
    static let blue = linear(0.15, 0.35, 0.9)
    static let gray = linear(0.5, 0.5, 0.5)

    @Test("The eight ranges match the Black & White mix's, in order around the hue circle")
    func ranges() {
        #expect(ColorRange.allCases.map(\.title) == ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"])
        let hues = ColorRange.allCases.map(\.hue)
        #expect(hues == hues.sorted() && hues.first == 0 && hues.last! < 360)
        #expect(ColorRange.red.previous == .magenta && ColorRange.magenta.next == .red)
        #expect(ColorRange.containing(hue: 350) == .red)
        #expect(ColorRange.containing(hue: 100) == .green)
        #expect(ColorRange.containing(hue: 200) == .aqua)
        #expect(ColorRange.containing(hue: -20) == .red)
    }

    @Test("With every range at 0 the stage passes the image through untouched")
    func neutralSkipsStage() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.2, blue: 0.1)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        var selective = SelectiveColor()
        #expect(SelectiveColorStage.apply(selective, to: image) === image)
        selective[.red] = ColorRangeAdjustment(hue: 10)
        #expect(SelectiveColorStage.apply(selective, to: image) !== image)
        selective[.red] = ColorRangeAdjustment()
        #expect(selective.isNeutral)
    }

    @Test("Values outside -100 to 100 are clamped")
    func clampsValues() {
        #expect(SelectiveColorStage.clamped(250) == 100)
        #expect(SelectiveColorStage.clamped(-180) == -100)
    }

    @Test("Saturation -100 on a range makes its colors gray and leaves other ranges alone")
    func saturationRemovesRange() throws {
        var selective = SelectiveColor()
        selective[.green] = ColorRangeAdjustment(saturation: -100)
        let green = try render(Self.green, selective)
        #expect(abs(green[0] - green[1]) < 1e-3 && abs(green[1] - green[2]) < 1e-3)
        #expect(close(try render(Self.orange, selective), Self.orange))
        #expect(close(try render(Self.blue, selective), Self.blue))
    }

    @Test("Hue +100 turns a range's center to the next range's center")
    func hueReachesNeighbor() throws {
        var selective = SelectiveColor()
        selective[.orange] = ColorRangeAdjustment(hue: 100)
        let turned = try render(Self.orange, selective)
        let hue = try #require(Histogram.hueAndSaturation(turned[0], turned[1], turned[2])).hue
        #expect(abs(hue - 60) < 0.5)
        selective[.orange] = ColorRangeAdjustment(hue: -100)
        let back = try render(Self.orange, selective)
        let red = try #require(Histogram.hueAndSaturation(back[0], back[1], back[2])).hue
        #expect(min(red, 360 - red) < 0.5)
    }

    @Test("Brightness darkens and lightens a range without changing its hue, and grays not at all")
    func brightnessMovesBothWays() throws {
        var selective = SelectiveColor()
        selective[.blue] = ColorRangeAdjustment(brightness: -100)
        let darker = try render(Self.blue, selective)
        #expect(darker[2] < Self.blue[2] * 0.5)
        selective[.blue] = ColorRangeAdjustment(brightness: 100)
        let lighter = try render(Self.blue, selective)
        #expect(lighter[2] > Self.blue[2])
        let before = try #require(Histogram.hueAndSaturation(Self.blue[0], Self.blue[1], Self.blue[2])).hue
        let after = try #require(Histogram.hueAndSaturation(lighter[0], lighter[1], lighter[2])).hue
        #expect(abs(before - after) < 1)

        for range in ColorRange.allCases { selective[range] = ColorRangeAdjustment(hue: 100, saturation: 100, brightness: 100) }
        #expect(close(try render(Self.gray, selective), Self.gray))
    }

    @Test("A hue between two ranges takes part of each, so no edge shows between them")
    func neighborsBlend() throws {
        var selective = SelectiveColor()
        selective[.green] = ColorRangeAdjustment(brightness: -100)
        // Hue 90°, halfway from yellow to green, sees half of green's darkening in stops.
        let between = Self.linear(0.6, 1, 0.2)
        let result = try render(between, selective)
        let stops = log2(result[1] / between[1])
        #expect(abs(stops + Float(SelectiveColorStage.brightnessStops) / 2) < 0.05)
    }

    @Test("The hue histogram counts colors by saturation in the range that adjusts them, and grays not at all")
    func hueHistogram() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        let half = CGRect(x: 0, y: 0, width: 8, height: 16)
        let image = Self.image(Self.green, half)
            .composited(over: Self.image(Self.gray, CGRect(x: 0, y: 0, width: 16, height: 16)))
        let bins = Histogram.measureHues(image, context: context)
        #expect(bins.count == Histogram.hueBinCount)
        let peak = bins.indices.max { bins[$0] < bins[$1] }!
        let hue = (Double(peak) + 0.5) / Double(Histogram.hueBinCount) * 360
        #expect(ColorRange.containing(hue: hue) == .green)
        let saturation = Histogram.hueAndSaturation(Self.green[0], Self.green[1], Self.green[2])!.saturation
        #expect(abs(bins.reduce(0, +) - saturation / 2) < 1e-3)
    }

    static func linear(_ r: Float, _ g: Float, _ b: Float) -> [Float] {
        [pow(r, 2.2), pow(g, 2.2), pow(b, 2.2)]
    }

    private func close(_ a: [Float], _ b: [Float]) -> Bool {
        zip(a.prefix(3), b.prefix(3)).allSatisfy { abs($0 - $1) < 1e-3 }
    }

    private static func image(_ color: [Float], _ rect: CGRect) -> CIImage {
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        return CIImage(color: CIColor(red: CGFloat(color[0]), green: CGFloat(color[1]), blue: CGFloat(color[2]),
                                      alpha: 1, colorSpace: space)!).cropped(to: rect)
    }

    private func render(_ color: [Float], _ selective: SelectiveColor) throws -> [Float] {
        let space = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let image = Self.image(color, CGRect(x: 0, y: 0, width: 1, height: 1))
        var pixel = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: space, .workingFormat: CIFormat.RGBAf])
        context.render(SelectiveColorStage.apply(selective, to: image), toBitmap: &pixel,
                       rowBytes: 16, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBAf, colorSpace: space)
        return pixel
    }
}
