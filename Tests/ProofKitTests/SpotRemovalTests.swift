import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct SpotRemovalTests {
    private let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    private let context = CIContext(options: [
        .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!,
        .workingFormat: CIFormat.RGBAf,
    ])
    /// 600 × 400, so a radius of 0.02 of the long edge is 12 pixels.
    private let size = CGSize(width: 600, height: 400)

    @Test("No spots pass the image through untouched")
    func noSpots() {
        let image = gray(0.18)
        #expect(SpotRemoval.apply([], to: image) === image)
    }

    @Test("Healing a dark dust spot on an even gray brings it back to the gray around it")
    func healsDust() throws {
        let image = dusty(background: 0.3, dust: 0.15)
        let spot = Spot(x: 0.5, y: 0.5, sourceX: 0.7, sourceY: 0.5, radius: 0.02)
        let result = SpotRemoval.apply([spot], to: image)
        #expect(try value(image, at: center) < 0.2)
        #expect(abs(try value(result, at: center) - 0.3) < 0.003)
        // Outside the circle nothing changes.
        #expect(abs(try value(result, at: CGPoint(x: 300 + 20, y: 200)) - 0.3) < 0.0005)
    }

    @Test("Healing matches the source to the brightness around the spot; cloning copies it as it is")
    func healMatchesCloneCopies() throws {
        // The left half is twice as bright as the right half, and the spot is on the left.
        let left = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
        let image = left.composited(over: gray(0.2))
        let healed = Spot(x: 0.2, y: 0.5, sourceX: 0.8, sourceY: 0.5, radius: 0.02)
        var cloned = healed
        cloned.mode = .clone
        let point = CGPoint(x: 120, y: 200)
        #expect(abs(try value(SpotRemoval.apply([healed], to: image), at: point) - 0.4) < 0.004)
        #expect(abs(try value(SpotRemoval.apply([cloned], to: image), at: point) - 0.2) < 0.001)
    }

    @Test("Heal and Clone spots in one edit each do their own work, in either order")
    func mixedModes() throws {
        let left = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 300, height: 400))
        let image = left.composited(over: gray(0.2))
        let healed = Spot(x: 0.2, y: 0.3, sourceX: 0.8, sourceY: 0.3, radius: 0.02)
        let cloned = Spot(mode: .clone, x: 0.2, y: 0.7, sourceX: 0.8, sourceY: 0.7, radius: 0.02)
        for spots in [[healed, cloned], [cloned, healed]] {
            let result = SpotRemoval.apply(spots, to: image)
            // y is from the top; Core Image's from the bottom.
            #expect(abs(try value(result, at: CGPoint(x: 120, y: 280)) - 0.4) < 0.004)
            #expect(abs(try value(result, at: CGPoint(x: 120, y: 120)) - 0.2) < 0.001)
        }
    }

    @Test("Opacity blends the fill with the photo, and Feather softens the edge")
    func opacityAndFeather() throws {
        let image = dusty(background: 0.3, dust: 0.1)
        var spot = Spot(mode: .clone, x: 0.5, y: 0.5, sourceX: 0.7, sourceY: 0.5, radius: 0.02, feather: 0, opacity: 50)
        #expect(abs(try value(SpotRemoval.apply([spot], to: image), at: center) - 0.2) < 0.002)
        // Inside the dust, a hard edge is fully covered and a full feather only partly.
        spot.opacity = 100
        let halfway = CGPoint(x: 303, y: 200)
        let hard = try value(SpotRemoval.apply([spot], to: image), at: halfway)
        spot.feather = 100
        let soft = try value(SpotRemoval.apply([spot], to: image), at: halfway)
        #expect(abs(hard - 0.3) < 0.002)
        #expect(soft < hard - 0.02)
    }

    @Test("A spot covers the same part of the photo at any render size")
    func scalesWithPhoto() throws {
        let spot = Spot(x: 0.5, y: 0.5, sourceX: 0.7, sourceY: 0.5, radius: 0.02)
        let small = dusty(background: 0.3, dust: 0.15).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        #expect(abs(try value(SpotRemoval.apply([spot], to: small), at: CGPoint(x: 150, y: 100)) - 0.3) < 0.004)
    }

    @Test("The chosen source avoids other dust and stays on the photo")
    func choosesCleanSource() throws {
        let width = 200, height = 100
        var grid = [Float](repeating: 0.3, count: width * height)
        // Dust at the center, and a second speck to its right where a source might go.
        func dot(_ cx: Int, _ cy: Int, _ r: Int) {
            for y in (cy - r)...(cy + r) { for x in (cx - r)...(cx + r) where (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r {
                grid[y * width + x] = 0.1
            } }
        }
        dot(100, 50, 3)
        dot(124, 50, 3)
        let region = CGRect(x: 0, y: 0, width: 1, height: 1)
        // A radius of 5 pixels on the 200-pixel long edge.
        let source = try #require(SpotRemoval.bestSource(center: CGPoint(x: 0.5, y: 0.5), radius: 0.025, aspect: 2,
                                                         luminance: grid, width: width, height: height, region: region))
        let px = CGPoint(x: source.x * 200, y: source.y * 100)
        #expect(hypot(px.x - 124, px.y - 50) > 10)
        #expect(px.x >= 5 && px.x <= 195 && px.y >= 5 && px.y <= 95)

        // A spot whose every candidate falls off the photo has none.
        #expect(SpotRemoval.bestSource(center: CGPoint(x: 0.5, y: 0.5), radius: 0.2, aspect: 2,
                                       luminance: grid, width: width, height: height, region: region) == nil)
    }

    @Test("For Clone the chosen source matches the brightness around the spot, not only its texture")
    func cloneSourceMatchesBrightness() throws {
        let width = 200, height = 200
        // Darker to the left of the spot, the same gray elsewhere; the dark side is smoother.
        var grid = [Float](repeating: 0.3, count: width * height)
        for y in 0..<height { for x in 0..<width {
            if x < 90 { grid[y * width + x] = 0.1 } else if (x + y) % 2 == 0 { grid[y * width + x] = 0.33 }
        } }
        let region = CGRect(x: 0, y: 0, width: 1, height: 1)
        let cloned = try #require(SpotRemoval.bestSource(center: CGPoint(x: 0.5, y: 0.5), radius: 0.025, mode: .clone,
                                                         aspect: 1, luminance: grid, width: width, height: height, region: region))
        #expect(cloned.x > 0.5)
    }

    // MARK: Strokes

    @Test("A stroke heals a dark line on an even gray all along its length and leaves the rest alone")
    func strokeHealsLine() throws {
        let image = scratched(background: 0.3, line: 0.12)
        // Along the line, 2 pixels thick from x 200 to 400 at y 200, with a radius of 6 pixels.
        let stroke = Spot(x: 0.3, y: 0.5, sourceX: 0.3, sourceY: 0.6, radius: 0.01,
                          path: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
        let result = SpotRemoval.apply([stroke], to: image)
        for x in [210.0, 300, 390] {
            #expect(try value(image, at: CGPoint(x: x, y: 200)) < 0.2)
            #expect(abs(try value(result, at: CGPoint(x: x, y: 200)) - 0.3) < 0.003)
        }
        // Beyond the stroke's end and well off its side nothing changes.
        let beyond = CGPoint(x: 440, y: 200)
        #expect(try abs(value(result, at: beyond) - value(image, at: beyond)) < 0.0005)
        #expect(abs(try value(result, at: CGPoint(x: 300, y: 215)) - 0.3) < 0.0005)
    }

    @Test("A stroke still taking from itself, as while it is painted, changes nothing")
    func strokeOnItselfChangesNothing() {
        let image = scratched(background: 0.3, line: 0.12)
        let stroke = Spot(x: 0.3, y: 0.5, sourceX: 0.3, sourceY: 0.5, radius: 0.01,
                          path: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
        #expect(SpotRemoval.apply([stroke], to: image) === image)
    }

    @Test("Clone, Opacity and Feather work on a stroke as on a circle")
    func strokeOpacityAndFeather() throws {
        let image = scratched(background: 0.3, line: 0.1)
        var stroke = Spot(mode: .clone, x: 0.3, y: 0.5, sourceX: 0.3, sourceY: 0.6, radius: 0.01, feather: 0, opacity: 50,
                          path: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
        let point = CGPoint(x: 300, y: 200)
        #expect(abs(try value(SpotRemoval.apply([stroke], to: image), at: point) - 0.2) < 0.003)
        // 4 pixels off the path of a 6-pixel radius: fully covered with a hard edge, partly with a soft one.
        stroke.opacity = 100
        let off = CGPoint(x: 300, y: 196)
        let darker = scratched(background: 0.3, line: 0.1, thickness: 10)
        let hard = try value(SpotRemoval.apply([stroke], to: darker), at: off)
        stroke.feather = 100
        let soft = try value(SpotRemoval.apply([stroke], to: darker), at: off)
        #expect(abs(hard - 0.3) < 0.003)
        #expect(soft < hard - 0.05)
    }

    @Test("A stroke covers the same part of the photo at any render size")
    func strokeScalesWithPhoto() throws {
        let stroke = Spot(x: 0.3, y: 0.5, sourceX: 0.3, sourceY: 0.6, radius: 0.01,
                          path: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.5)])
        let small = scratched(background: 0.3, line: 0.12, thickness: 4).transformed(by: CGAffineTransform(scaleX: 0.5, y: 0.5))
        #expect(abs(try value(SpotRemoval.apply([stroke], to: small), at: CGPoint(x: 150, y: 100)) - 0.3) < 0.004)
    }

    @Test("A circle spot renders exactly as it did before strokes")
    func circleUnchanged() throws {
        let image = dusty(background: 0.3, dust: 0.15)
        let spot = Spot(x: 0.5, y: 0.5, sourceX: 0.7, sourceY: 0.5, radius: 0.02)
        // A single point is no stroke, and renders as the circle at the spot's position.
        var dot = spot
        dot.points = [0.5, 0.5]
        #expect(!dot.isStroke)
        for point in [center, CGPoint(x: 310, y: 200), CGPoint(x: 312, y: 205)] {
            #expect(try value(SpotRemoval.apply([dot], to: image), at: point) == value(SpotRemoval.apply([spot], to: image), at: point))
        }
    }

    @Test("Moving a stroke moves its whole path, and its source stays where it was")
    func movingStroke() {
        var stroke = Spot(x: 0.3, y: 0.5, sourceX: 0.3, sourceY: 0.6,
                          path: [CGPoint(x: 0.3, y: 0.5), CGPoint(x: 0.7, y: 0.4)])
        stroke.center = CGPoint(x: 0.35, y: 0.45)
        #expect(stroke.path.count == 2)
        #expect(abs(stroke.path[1].x - 0.75) < 1e-12 && abs(stroke.path[1].y - 0.35) < 1e-12)
        #expect(stroke.path[0] == stroke.center)
        #expect(stroke.source == CGPoint(x: 0.3, y: 0.6))
    }

    @Test("A stroke's chosen source avoids a second line beside it and doesn't slide along itself")
    func strokeSourceAvoidsOtherLine() throws {
        let width = 200, height = 200
        var grid = [Float](repeating: 0.3, count: width * height)
        func line(atRow row: Int) {
            for y in (row - 1)...(row + 1) { for x in 50..<150 { grid[y * width + x] = 0.1 } }
        }
        // The hair at row 100, and a second one 12 pixels below it, where a source 2.4 radii
        // straight down would go.
        line(atRow: 100)
        line(atRow: 112)
        let region = CGRect(x: 0, y: 0, width: 1, height: 1)
        let path = [CGPoint(x: 0.25, y: 0.5), CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0.75, y: 0.5)]
        // A radius of 5 pixels.
        let offset = try #require(SpotRemoval.bestOffset(path: path, radius: 0.025, aspect: 1, luminance: grid,
                                                         width: width, height: height, region: region))
        let moved = (dx: offset.dx * 200, dy: offset.dy * 200)
        // Up, away from the second line, not sideways along the hair.
        #expect(moved.dy < -10)
        #expect(abs(moved.dx) < abs(moved.dy))
    }

    @Test("A stroke is sampled evenly along its length, however its points were spaced")
    func resamplesPath() {
        let points = SpotRemoval.resampled([CGPoint(x: 0, y: 0), CGPoint(x: 0.1, y: 0), CGPoint(x: 0.1001, y: 0)],
                                           spacing: 0.5, rx: 0.01, ry: 0.01)
        // 10 radii long at half a radius apart, with both ends.
        #expect(points.count == 22)
        #expect(points.first == CGPoint(x: 0, y: 0) && points.last == CGPoint(x: 0.1001, y: 0))
        let long = SpotRemoval.resampled([CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0)], spacing: 0.5, rx: 0.001, ry: 0.001)
        #expect(long.count <= 49)
    }

    // MARK: Helpers

    private var center: CGPoint { CGPoint(x: 300, y: 200) }

    private func gray(_ value: CGFloat) -> CIImage {
        CIImage(color: CIColor(red: value, green: value, blue: value, colorSpace: linear)!)
            .cropped(to: CGRect(origin: .zero, size: size))
    }

    /// An even gray with a dark disc 6 pixels across at the center.
    private func dusty(background: CGFloat, dust: CGFloat) -> CIImage {
        let disc = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: 300, y: 200), "inputRadius0": 5, "inputRadius1": 6,
            "inputColor0": CIColor(red: dust, green: dust, blue: dust, colorSpace: linear)!,
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])!.outputImage!
        return disc.composited(over: gray(background)).cropped(to: CGRect(origin: .zero, size: size))
    }

    /// An even gray with a dark horizontal line `thickness` pixels thick from x 200 to 400 across the middle.
    private func scratched(background: CGFloat, line: CGFloat, thickness: CGFloat = 2) -> CIImage {
        let dark = CIImage(color: CIColor(red: line, green: line, blue: line, colorSpace: linear)!)
            .cropped(to: CGRect(x: 200, y: 200 - thickness / 2, width: 200, height: thickness))
        return dark.composited(over: gray(background))
    }

    private func value(_ image: CIImage, at point: CGPoint) throws -> Double {
        var values = [Float](repeating: 0, count: 4)
        context.render(image, toBitmap: &values, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                       format: .RGBAf, colorSpace: linear)
        return Double(values[1])
    }
}

struct SpotSourceTests {
    @Test("A new spot on a real photo takes from a nearby circle on the photo, and the same spot always from the same one",
          .enabled(if: sampleDNG != nil))
    func picksSourceOnRealPhoto() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        // As the canvas leaves it, at about a window's size.
        _ = try await renderer.render(fitting: CGSize(width: 1600, height: 1000))
        let center = CGPoint(x: 0.48, y: 0.4)
        let start = ContinuousClock.now
        let source = try #require(try await renderer.spotSource(center: center, radius: 0.02, recipe: EditRecipe()))
        print("Spot source: \(source) in \(ContinuousClock.now - start)")
        let distance = hypot(source.x - center.x, (source.y - center.y) * 2 / 3)
        #expect(distance > 0.04 && distance < 0.08)
        if checksTiming { #expect(ContinuousClock.now - start < .milliseconds(300)) }
        #expect(try await renderer.spotSource(center: center, radius: 0.02, recipe: EditRecipe()) == source)
    }
}
