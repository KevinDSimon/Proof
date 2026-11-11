import CoreImage
import Foundation
import Testing
import simd
@testable import ProofKit

struct PerspectiveTransformTests {
    static let size = CGSize(width: 600, height: 400)

    /// The four sides of a building's front, as a camera tilted by `transform`'s opposite would
    /// draw them: upright and level lines that `transform` then makes upright and level again.
    static func building(seenThrough transform: PerspectiveTransform) -> [LineSegment] {
        let inverse = transform.homography(for: size).inverse
        func line(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> LineSegment {
            LineSegment(start: PerspectiveTransform.apply(inverse, to: a), end: PerspectiveTransform.apply(inverse, to: b))
        }
        return [line(SIMD2(150, 60), SIMD2(150, 340)), line(SIMD2(450, 60), SIMD2(450, 340)),
                line(SIMD2(300, 80), SIMD2(300, 320)),
                line(SIMD2(170, 100), SIMD2(430, 100)), line(SIMD2(170, 300), SIMD2(430, 300))]
    }

    @Test("Neutral sliders leave the photo where it is")
    func neutralIsIdentity() {
        #expect(PerspectiveTransform().homography(for: Self.size) == matrix_identity_double3x3)
        #expect(PerspectiveTransform(constrainCrop: false, upright: .auto).isNeutral)
    }

    @Test("Negative Vertical widens the top of the photo and keeps its center in place")
    func verticalWidensTop() {
        let map = PerspectiveTransform(vertical: -40, constrainCrop: false).homography(for: Self.size)
        let corners = PerspectiveTransform.corners(of: Self.size).map { PerspectiveTransform.apply(map, to: $0) }
        let top = corners[1].x - corners[0].x, bottom = corners[2].x - corners[3].x
        #expect(top > bottom * 1.15)
        let center = PerspectiveTransform.apply(map, to: SIMD2(300, 200))
        #expect(simd_distance(center, SIMD2(300, 200)) < 1e-6)
    }

    @Test("Negative Horizontal widens the left side, and Rotate turns clockwise")
    func horizontalAndRotate() {
        let tilted = PerspectiveTransform(horizontal: -40, constrainCrop: false).homography(for: Self.size)
        let c = PerspectiveTransform.corners(of: Self.size).map { PerspectiveTransform.apply(tilted, to: $0) }
        #expect(c[3].y - c[0].y > (c[2].y - c[1].y) * 1.2)
        let turned = PerspectiveTransform(rotate: 5, constrainCrop: false).homography(for: Self.size)
        // Clockwise on screen, with y downward: a point right of center moves down.
        #expect(PerspectiveTransform.apply(turned, to: SIMD2(500, 200)).y > 200)
    }

    @Test("Constrain Crop fills the frame with the corrected photo, with nothing empty")
    func constrainCropFills() {
        for transform in [PerspectiveTransform(vertical: -60), PerspectiveTransform(horizontal: 35, rotate: 4),
                          PerspectiveTransform(vertical: 30, horizontal: -20, aspect: 40)] {
            let inverse = transform.homography(for: Self.size).inverse
            for corner in PerspectiveTransform.corners(of: Self.size) {
                let source = PerspectiveTransform.apply(inverse, to: corner)
                #expect(source.x >= -1e-6 && source.x <= 600 + 1e-6 && source.y >= -1e-6 && source.y <= 400 + 1e-6)
            }
            // And as large as it can be: the frame's corners reach close to the photo's edges.
            let reach = PerspectiveTransform.corners(of: Self.size).map { corner -> Double in
                let s = PerspectiveTransform.apply(inverse, to: corner)
                return min(s.x, 600 - s.x, s.y, 400 - s.y)
            }
            #expect(reach.filter { $0 < 3 }.count >= 2)
        }
    }

    @Test("Vertical Upright makes converging uprights parallel and level")
    func uprightVertical() throws {
        let segments = Self.building(seenThrough: PerspectiveTransform(vertical: -35, rotate: 2, constrainCrop: false))
        let solved = try #require(Upright.solve(.vertical, segments: segments, size: Self.size, from: PerspectiveTransform()))
        #expect(abs(solved.vertical - -35) < 0.5)
        #expect(abs(solved.rotate - 2) < 0.05)
        #expect(solved.horizontal == 0)
        #expect(solved.upright == .vertical)
    }

    @Test("Full Upright corrects both tilts, and Level only turns")
    func uprightFullAndLevel() throws {
        let segments = Self.building(seenThrough: PerspectiveTransform(vertical: 25, horizontal: -30, rotate: -3, constrainCrop: false))
        let full = try #require(Upright.solve(.full, segments: segments, size: Self.size, from: PerspectiveTransform()))
        #expect(abs(full.vertical - 25) < 0.5)
        #expect(abs(full.horizontal - -30) < 0.5)
        #expect(abs(full.rotate - -3) < 0.05)
        let level = try #require(Upright.solve(.level, segments: segments, size: Self.size, from: PerspectiveTransform()))
        #expect(level.vertical == 0 && level.horizontal == 0)
        #expect(abs(level.rotate - -3) < 1)
    }

    @Test("Auto holds back a strong tilt but corrects it most of the way")
    func uprightAuto() throws {
        let segments = Self.building(seenThrough: PerspectiveTransform(vertical: -50, constrainCrop: false))
        let auto = try #require(Upright.solve(.auto, segments: segments, size: Self.size, from: PerspectiveTransform()))
        #expect(auto.vertical < -25 && auto.vertical > -50)
    }

    @Test("A line far from upright or level, such as a roof, doesn't sway Upright")
    func uprightIgnoresDiagonals() throws {
        var segments = Self.building(seenThrough: PerspectiveTransform(vertical: -30, constrainCrop: false))
        segments.append(LineSegment(start: SIMD2(100, 300), end: SIMD2(400, 120)))
        segments.append(LineSegment(start: SIMD2(310, 50), end: SIMD2(320, 350)))
        let solved = try #require(Upright.solve(.vertical, segments: segments, size: Self.size, from: PerspectiveTransform()))
        #expect(abs(solved.vertical - -30) < 3)
    }

    @Test("Guided straightens the drawn lines and keeps them and the other sliders")
    func guided() throws {
        let truth = PerspectiveTransform(vertical: -20, horizontal: 15, rotate: 1.5, constrainCrop: false)
        let lines = Self.building(seenThrough: truth)
        var transform = PerspectiveTransform(aspect: 12, scale: 110)
        transform.guides = [lines[0], lines[1], lines[3], lines[4]].map {
            GuideLine(start: CGPoint(x: $0.start.x / 600, y: $0.start.y / 400), end: CGPoint(x: $0.end.x / 600, y: $0.end.y / 400))
        }
        let solved = try #require(Upright.solve(.guided, segments: [], size: Self.size, from: transform))
        #expect(abs(solved.vertical - -20) < 0.3 && abs(solved.horizontal - 15) < 0.3 && abs(solved.rotate - 1.5) < 0.05)
        #expect(solved.aspect == 12 && solved.scale == 110 && solved.guides.count == 4)
        // One upright guide only turns the photo.
        transform.guides = [transform.guides[0]]
        let one = try #require(Upright.solve(.guided, segments: [], size: Self.size, from: transform))
        #expect(one.vertical == 0 && one.horizontal == 0)
    }

    @Test("Upright finds nothing to do without lines")
    func uprightWithoutLines() {
        #expect(Upright.solve(.auto, segments: [], size: Self.size, from: PerspectiveTransform()) == nil)
    }

    @Test("Line detection finds a drawn edge's ends to within a couple of pixels")
    func detectsLines() throws {
        let (w, h) = (400, 300)
        var gray = [Float](repeating: 0.2, count: w * h)
        // A light band whose left edge runs from (100, 40) to (130, 260): a slightly leaning upright.
        for y in 0..<h {
            for x in 0..<w {
                // Smoothed across the edge, by how much of each pixel lies right of it, as a lens draws it.
                let edge = 100 + 30 * (Double(y) + 0.5 - 40) / 220
                let covered = Float(min(max(Double(x) + 1 - edge, 0), 1))
                if y >= 40, y < 260, x < 300 { gray[y * w + x] = 0.2 + 0.6 * covered }
            }
        }
        let segments = LineDetector.segments(in: gray, width: w, height: h)
        let leaning = try #require(segments.first { $0.isCloserToUpright && abs($0.tilt) < 85 })
        let (top, bottom) = leaning.start.y < leaning.end.y ? (leaning.start, leaning.end) : (leaning.end, leaning.start)
        #expect(abs(top.y - 40) < 3 && abs(bottom.y - 260) < 3)
        #expect(abs(top.x - 100) < 2 && abs(bottom.x - 130) < 2)
        #expect(abs(leaning.tilt) - 90 + atan2(30, 220) * 180 / .pi < 0.5)
    }

    /// A building's front, lit from the side, with rows of windows: what a camera aimed straight
    /// at it would draw, at `size`, row by row from the top, from 0 to 1.
    static func facade(width: Int, height: Int) -> CIImage {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.setFillColor(gray: 0.75, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(gray: 0.45, alpha: 1)
        let wall = CGRect(x: Double(width) * 0.2, y: Double(height) * 0.05, width: Double(width) * 0.6, height: Double(height) * 0.9)
        context.fill(wall)
        context.setFillColor(gray: 0.15, alpha: 1)
        for row in 0..<6 {
            for column in 0..<5 {
                context.fill(CGRect(x: wall.minX + wall.width * (0.08 + Double(column) * 0.185), y: wall.minY + wall.height * (0.06 + Double(row) * 0.155),
                                    width: wall.width * 0.1, height: wall.height * 0.09))
            }
        }
        return CIImage(cgImage: context.makeImage()!).applyingGaussianBlur(sigma: 0.8)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
    }

    static func gray(of image: CIImage, width: Int, height: Int) -> [Float] {
        var bitmap = [Float](repeating: 0, count: width * height * 4)
        CIContext().render(image, toBitmap: &bitmap, rowBytes: width * 16, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                           format: .RGBAf, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // Core Image writes the top row first, as the detector reads them.
        return (0..<(width * height)).map { bitmap[$0 * 4] }
    }

    @Test("Upright finds a building seen from below in its picture and straightens it")
    func endToEnd() throws {
        let (w, h) = (900, 600)
        // Looking up at the front: the top narrows, as positive Vertical draws it.
        let seen = PerspectiveTransform.apply(PerspectiveTransform(vertical: 30, constrainCrop: false),
                                              to: Self.facade(width: w, height: h))
        let segments = LineDetector.segments(in: Self.gray(of: seen, width: w, height: h), width: w, height: h)
        #expect(segments.filter(\.isCloserToUpright).count >= 4)
        let size = CGSize(width: w, height: h)
        let solved = try #require(Upright.solve(.vertical, segments: segments, size: size, from: PerspectiveTransform()))
        #expect(solved.vertical < -25 && solved.vertical > -35)
        #expect(abs(solved.rotate) < 0.5)
        // The wall's sides come out upright: each found upright, corrected, leans less than half a degree.
        let map = solved.homography(for: size)
        for segment in segments where segment.isCloserToUpright && segment.length > 100 {
            let corrected = LineSegment(start: PerspectiveTransform.apply(map, to: segment.start),
                                        end: PerspectiveTransform.apply(map, to: segment.end))
            #expect(90 - abs(corrected.tilt) < 0.5)
        }
    }

    @Test("Flat or noisy images give no lines")
    func noLinesInNoise() {
        let (w, h) = (200, 150)
        var generator = SystemRandomNumberGenerator()
        let noise = (0..<(w * h)).map { _ in Float.random(in: 0.49...0.51, using: &generator) }
        #expect(LineDetector.segments(in: noise, width: w, height: h).isEmpty)
        #expect(LineDetector.segments(in: [Float](repeating: 0.5, count: w * h), width: w, height: h).isEmpty)
    }

    @Test("The render keeps the photo's extent, fills it with Constrain Crop, and leaves edges clear without")
    func render() {
        let image = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(origin: .zero, size: Self.size))
        func alpha(_ transform: PerspectiveTransform, at point: CGPoint) -> Float {
            let out = PerspectiveTransform.apply(transform, to: image)
            #expect(out.extent == image.extent)
            var pixel = [Float](repeating: 0, count: 4)
            CIContext().render(out, toBitmap: &pixel, rowBytes: 16, bounds: CGRect(origin: point, size: CGSize(width: 1, height: 1)),
                               format: .RGBAf, colorSpace: nil)
            return pixel[3]
        }
        // Positive Vertical narrows the top. Core Image's y points up, so the top-left corner is
        // the top row of the extent.
        let topLeft = CGPoint(x: 0, y: Self.size.height - 1)
        #expect(alpha(PerspectiveTransform(vertical: 50), at: topLeft) > 0.99)
        #expect(alpha(PerspectiveTransform(vertical: 50, constrainCrop: false), at: topLeft) < 0.01)
        #expect(alpha(PerspectiveTransform(), at: topLeft) > 0.99)
    }

    @Test("An edit saved before Transform reads as neutral, and one with it survives a round trip")
    func coding() throws {
        let old = try JSONDecoder().decode(EditRecipe.self, from: Data(#"{"formatVersion": 3, "processVersion": 1}"#.utf8))
        #expect(old.transform == PerspectiveTransform() && old.isNeutral)
        var recipe = EditRecipe()
        recipe.transform = PerspectiveTransform(vertical: -22, horizontal: 4, rotate: -1.2, aspect: 10, scale: 95,
                                                xOffset: 3, yOffset: -7, constrainCrop: false, upright: .guided,
                                                guides: [GuideLine(start: CGPoint(x: 0.1, y: 0.2), end: CGPoint(x: 0.12, y: 0.9))])
        let decoded = try JSONDecoder().decode(EditRecipe.self, from: JSONEncoder().encode(recipe))
        #expect(decoded == recipe && !decoded.isNeutral)
        #expect(decoded.original.transform == recipe.transform)
    }
}

struct UprightSampleTests {
    /// RAW files can't be committed, so this runs only when `PROOF_SAMPLE_DNG` names one.
    @Test("On a real photo, Upright finds lines quickly and chooses sliders in range",
          .enabled(if: sampleDNG != nil))
    func sampleUpright() async throws {
        let renderer = try RAWRenderer()
        try await renderer.open(try #require(sampleDNG))
        let start = ContinuousClock.now
        let found = try await renderer.uprightSegments(recipe: EditRecipe())
        print("Upright: \(found.segments.count) segments in \(found.size) in \(ContinuousClock.now - start)")
        for mode in [UprightMode.auto, .level, .vertical, .full] {
            let solved = Upright.solve(mode, segments: found.segments, size: found.size, from: PerspectiveTransform())
            print("Upright \(mode): \(solved.map { ($0.vertical, $0.horizontal, $0.rotate) } as Any)")
            if let solved {
                #expect(PerspectiveTransform.tiltRange.contains(solved.vertical))
                #expect(PerspectiveTransform.rotateRange.contains(solved.rotate))
            }
        }
    }
}
