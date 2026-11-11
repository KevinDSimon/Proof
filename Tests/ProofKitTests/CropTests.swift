import CoreGraphics
import CoreImage
import Foundation
import Testing
@testable import ProofKit

struct CropTests {
    private let landscape = CGSize(width: 300, height: 200)

    // MARK: Stored values

    @Test("A crop survives a JSON round trip, with its ratio as a two-element array")
    func roundTrip() throws {
        let crop = Crop(x: 0.1, y: 0.2, width: 0.5, height: 0.6, angle: -3.5, rotation: 270,
                        flipHorizontal: true, aspect: AspectRatio(4, 5))
        let data = try JSONEncoder().encode(crop)
        #expect(String(decoding: data, as: UTF8.self).contains(#""aspect":[4,5]"#))
        #expect(try JSONDecoder().decode(Crop.self, from: data) == crop)
    }

    @Test("A crop that changes nothing is the identity, whatever ratio is locked")
    func identity() {
        #expect(Crop().isIdentity)
        #expect(Crop(aspect: AspectRatio(1, 1)).isIdentity)
        #expect(!Crop(rotation: 90).isIdentity)
        #expect(!Crop(flipVertical: true).isIdentity)
        #expect(!Crop(angle: 0.5).isIdentity)
        #expect(!Crop(width: 0.9).isIdentity)
    }

    @Test("A photo with no crop starts locked to its own shape, which turns with it")
    func uncroppedIsOriginal() {
        var crop = Crop.uncropped(photoSize: landscape)
        #expect(crop.isIdentity)
        #expect(crop.aspect == AspectRatio(300, 200))
        crop.rotate(clockwise: true)
        #expect(crop.aspect == AspectRatio(200, 300))
        #expect(Crop.uncropped(photoSize: nil).aspect == nil)
    }

    @Test("Turning a quarter turn swaps the output's width and height")
    func outputSize() {
        let crop = Crop(x: 0, y: 0, width: 0.5, height: 1, rotation: 90)
        #expect(crop.outputSize(of: landscape) == CGSize(width: 100, height: 300))
    }

    // MARK: Turning and flipping

    @Test("Turning clockwise carries the rectangle and ratio with the photo")
    func rotateClockwise() {
        var crop = Crop(x: 0.1, y: 0.2, width: 0.3, height: 0.4, aspect: AspectRatio(3, 4))
        crop.rotate(clockwise: true)
        // The rectangle's top left was at (0.1, 0.2); a clockwise turn puts its bottom left there.
        #expect(abs(crop.x - 0.4) < 1e-9 && abs(crop.y - 0.1) < 1e-9)
        #expect(crop.width == 0.4 && crop.height == 0.3)
        #expect(crop.rotation == 90)
        #expect(crop.aspect == AspectRatio(4, 3))
    }

    @Test("Four turns in either direction return to the start")
    func fourTurns() {
        let start = Crop(x: 0.1, y: 0.2, width: 0.3, height: 0.4, angle: 2)
        for clockwise in [true, false] {
            var crop = start
            for _ in 0..<4 { crop.rotate(clockwise: clockwise) }
            #expect(abs(crop.x - start.x) < 1e-9 && abs(crop.y - start.y) < 1e-9)
            #expect(crop.rotation == 0 && crop.angle == start.angle)
        }
        var crop = start
        crop.rotate(clockwise: true)
        crop.rotate(clockwise: false)
        #expect(crop.rotation == 0)
    }

    @Test("Flipping mirrors the rectangle and the straighten angle")
    func flip() {
        var crop = Crop(x: 0.1, y: 0.2, width: 0.3, height: 0.4, angle: 5)
        crop.flipHorizontally()
        #expect(abs(crop.x - 0.6) < 1e-9 && crop.y == 0.2)
        #expect(crop.angle == -5 && crop.flipHorizontal)
        crop.flipVertically()
        #expect(abs(crop.y - 0.4) < 1e-9 && crop.angle == 5)
    }

    @Test("Both flips together are stored as a half turn")
    func bothFlips() {
        var crop = Crop()
        crop.flipHorizontally()
        crop.flipVertically()
        #expect(!crop.flipHorizontal && !crop.flipVertical && crop.rotation == 180)
    }

    @Test("A flipped photo still turns clockwise on screen")
    func turnAfterFlip() throws {
        var crop = Crop()
        crop.flipHorizontally()
        crop.rotate(clockwise: true)
        // Flip, then a clockwise turn, is the same picture as a counterclockwise turn, then flip.
        #expect(crop.rotation == 270 && crop.flipHorizontal)
        let image = try quadrants()
        let rendered = RAWRenderer.applyGeometry(crop, to: image)
        // The flipped photo has red at the top right; turned clockwise, that is the bottom right.
        #expect(try color(of: rendered, atTop: false, left: false) == .red)
    }

    // MARK: Fitting the rectangle on the photo

    @Test("The whole photo fits; straightened, it shrinks to keep its corners on the photo")
    func straightenShrinks() {
        let whole = CropFrame.whole(landscape)
        #expect(whole.fits)
        let tilted = whole.straightened(10)
        #expect(tilted.fits)
        #expect(tilted.size.width < landscape.width)
        #expect(abs(tilted.size.width / tilted.size.height - 1.5) < 1e-9)
        #expect(tilted.center == whole.center)
        // Not smaller than it needs to be: one corner touches an edge.
        let touches = tilted.corners.contains { min($0.x, $0.y, landscape.width - $0.x, landscape.height - $0.y) < 1e-6 }
        #expect(touches)
    }

    @Test("Straightening back to zero returns the rectangle it started from")
    func straightenReturns() {
        let start = CropFrame.whole(landscape)
        #expect(start.straightened(20).angle == 20)
        #expect(start.straightened(0) == start)
        #expect(start.straightened(90).angle == 45)
    }

    @Test("A locked ratio takes the largest rectangle of that shape around the center")
    func aspect() {
        let square = CropFrame.whole(landscape).withAspect(AspectRatio(1, 1))
        #expect(square.size == CGSize(width: 200, height: 200))
        let freeform = square.withAspect(nil)
        #expect(freeform.size == landscape)
    }

    @Test("Dragging a corner outward stops at the photo's edges")
    func dragStopsAtEdge() {
        let start = CropFrame(center: CGPoint(x: 150, y: 100), size: CGSize(width: 100, height: 100),
                              angle: 0, imageSize: landscape)
        let dragged = start.dragging(.bottomRight, by: CGVector(dx: 500, dy: 20), aspect: nil)
        // Freeform: the right edge stops at the photo's, the bottom edge keeps its full move.
        #expect(abs(dragged.size.width - 200) < 0.01)
        #expect(abs(dragged.size.height - 120) < 0.01)
        #expect(abs((dragged.center.x - dragged.size.width / 2) - 100) < 0.01)
    }

    @Test("Dragging with a locked ratio keeps the shape and the opposite corner")
    func dragKeepsAspect() {
        let start = CropFrame(center: CGPoint(x: 150, y: 100), size: CGSize(width: 60, height: 40),
                              angle: 0, imageSize: landscape)
        let dragged = start.dragging(.topLeft, by: CGVector(dx: -30, dy: 0), aspect: AspectRatio(3, 2))
        #expect(abs(dragged.size.width - 90) < 1e-9 && abs(dragged.size.height - 60) < 1e-9)
        #expect(abs(dragged.center.x + dragged.size.width / 2 - 180) < 1e-9)
        #expect(abs(dragged.center.y + dragged.size.height / 2 - 120) < 1e-9)
    }

    @Test("A rectangle can't be dragged smaller than the smallest size")
    func dragMinimum() {
        let start = CropFrame.whole(landscape)
        let dragged = start.dragging(.right, by: CGVector(dx: -1000, dy: 0), aspect: nil)
        #expect(abs(dragged.size.width - 10) < 1e-9)
    }

    @Test("Moving a tilted rectangle slides it along the photo's edge")
    func moveStopsAtEdge() {
        let start = CropFrame.whole(landscape).withAspect(AspectRatio(1, 1)).straightened(5)
        let moved = start.moved(by: CGVector(dx: 1000, dy: 0))
        #expect(moved.fits)
        #expect(moved.center.x > start.center.x)
        #expect(moved.size == start.size)
    }

    @Test("A frame converts to a crop and back")
    func frameRoundTrip() {
        let crop = Crop(x: 0.1, y: 0.2, width: 0.5, height: 0.6, angle: 3, rotation: 90, aspect: AspectRatio(5, 4))
        let frame = CropFrame(crop, imageSize: landscape)
        let back = frame.applied(to: crop)
        #expect(abs(back.x - crop.x) < 1e-9 && abs(back.y - crop.y) < 1e-9)
        #expect(abs(back.width - crop.width) < 1e-9 && back.rotation == 90 && back.aspect == crop.aspect)
    }

    // MARK: Rendering

    @Test("A quarter turn renders the photo turned clockwise")
    func renderTurn() throws {
        let image = try quadrants()
        let turned = RAWRenderer.applyGeometry(Crop(rotation: 90), to: image)
        #expect(turned.extent == CGRect(x: 0, y: 0, width: 20, height: 40))
        // Red starts at the top left; a clockwise turn takes it to the top right.
        #expect(try color(of: turned, atTop: true, left: false) == .red)
    }

    @Test("A flip renders the photo mirrored")
    func renderFlip() throws {
        let image = try quadrants()
        #expect(try color(of: RAWRenderer.applyGeometry(Crop(flipHorizontal: true), to: image), atTop: true, left: false) == .red)
        #expect(try color(of: RAWRenderer.applyGeometry(Crop(flipVertical: true), to: image), atTop: false, left: true) == .red)
    }

    @Test("A crop renders only its rectangle, measured from the top left")
    func renderCrop() throws {
        let image = try quadrants()
        let cropped = RAWRenderer.applyGeometry(Crop(x: 0, y: 0, width: 0.5, height: 0.5), to: image)
        #expect(cropped.extent == CGRect(x: 0, y: 0, width: 20, height: 10))
        #expect(try color(of: cropped, atTop: true, left: true) == .red)
        #expect(try color(of: cropped, atTop: false, left: false) == .red)
    }

    @Test("Straightening keeps the crop's size and turns the photo under it")
    func renderStraighten() throws {
        let image = try quadrants()
        let crop = CropFrame.whole(CGSize(width: 40, height: 20)).straightened(10).applied(to: Crop())
        let rendered = RAWRenderer.applyGeometry(crop, to: image)
        // In whole pixels, never more than the crop covers.
        let expected = CGSize(width: (crop.width * 40).rounded(.down), height: (crop.height * 20).rounded(.down))
        #expect(rendered.extent.size == expected)
        #expect(rendered.extent.origin == .zero)
    }

    @Test("Scaling for the window fits the cropped photo, not the whole one")
    func scaleFitsCrop() {
        let m11 = CGSize(width: 9504, height: 6320)
        let crop = Crop(x: 0, y: 0, width: 0.5, height: 1, rotation: 90)
        // Turned, the photo is 6320 × 9504; half its width is 3160 × 9504.
        let scale = RAWRenderer.scaleFactor(nativeSize: m11, orientation: .up, crop: crop,
                                            fitting: CGSize(width: 2000, height: 950.4))
        #expect(abs(scale - 0.1) < 0.0001)
    }

    // MARK: Helpers

    private enum Quadrant: Equatable { case red, other }

    /// 40 × 20 pixels: red in the top-left quarter, gray elsewhere.
    private func quadrants() throws -> CIImage {
        let gray = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 40, height: 20))
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: 10, width: 20, height: 10))
        return red.composited(over: gray)
    }

    /// Whether the middle of a quarter of `image` is red.
    private func color(of image: CIImage, atTop top: Bool, left: Bool) throws -> Quadrant {
        let extent = image.extent
        let x = extent.minX + extent.width * (left ? 0.25 : 0.75)
        // Core Image's origin is at the bottom left.
        let y = extent.minY + extent.height * (top ? 0.75 : 0.25)
        var pixel = [UInt8](repeating: 0, count: 4)
        CIContext().render(image, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: x.rounded(.down), y: y.rounded(.down), width: 1, height: 1),
                           format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return pixel[0] > 200 && pixel[1] < 50 ? .red : .other
    }
}

struct CropPointTests {
    /// Where the one bright pixel of `image` lands, in pixels from the top left.
    static func brightest(in image: CIImage) -> CGPoint {
        let extent = image.extent.integral
        let (w, h) = (Int(extent.width), Int(extent.height))
        var bitmap = [Float](repeating: 0, count: w * h * 4)
        CIContext().render(image, toBitmap: &bitmap, rowBytes: w * 16, bounds: extent, format: .RGBAf, colorSpace: nil)
        var best = (value: Float(-1), x: 0, y: 0)
        for y in 0..<h { for x in 0..<w where bitmap[(y * w + x) * 4] > best.value { best = (bitmap[(y * w + x) * 4], x, y) } }
        return CGPoint(x: Double(best.x) + 0.5, y: Double(best.y) + 0.5)
    }

    @Test("A point of the photo maps to where the crop's render puts it, and back", arguments: [
        Crop(x: 0.1, y: 0.15, width: 0.7, height: 0.6, angle: 7),
        Crop(x: 0.05, y: 0.1, width: 0.8, height: 0.7, angle: -5, rotation: 90, flipHorizontal: true),
        Crop(x: 0.2, y: 0, width: 0.6, height: 0.9, angle: 3, rotation: 270, flipVertical: true),
        Crop(rotation: 180),
    ])
    func pointsFollowTheRender(crop: Crop) throws {
        let size = CGSize(width: 400, height: 300)
        // A bright dot at (150, 120) from the top left; Core Image's y points up.
        let dot = CIImage(color: .white).cropped(to: CGRect(x: 149, y: 300 - 121, width: 2, height: 2))
        let photo = dot.composited(over: CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: size)))
        let rendered = RAWRenderer.applyGeometry(crop, to: photo)
        let found = Self.brightest(in: rendered)
        let point = CGPoint(x: 150.0 / 400, y: 120.0 / 300)
        let mapped = crop.resultPoint(of: point, photoSize: size)
        #expect(abs(mapped.x * rendered.extent.width - found.x) < 2)
        #expect(abs(mapped.y * rendered.extent.height - found.y) < 2)
        let back = crop.photoPoint(of: mapped, photoSize: size)
        #expect(abs(back.x - point.x) < 1e-9 && abs(back.y - point.y) < 1e-9)
    }
}
