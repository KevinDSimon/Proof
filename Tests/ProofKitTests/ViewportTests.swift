import CoreGraphics
import Testing
@testable import ProofKit

struct ViewportTests {
    /// A 60 MP photo in a window about 2000 pixels wide: Fit is 0.2, below the smallest step.
    private let photo = CGSize(width: 9528, height: 6328)
    private let view = CGSize(width: 2000, height: 1400)

    // MARK: Steps

    @Test("Zoom In from Fit goes through the steps larger than Fit, then stops at 400%")
    func zoomInSteps() {
        var viewport = Viewport()
        var scales: [Double?] = []
        while viewport.canZoomIn(photo: photo, view: view) {
            viewport = viewport.zoomedIn(photo: photo, view: view)
            scales.append(viewport.scale)
        }
        #expect(scales == [0.25, 0.5, 1, 2, 4])
    }

    @Test("Zoom Out ends at Fit when Fit is the smallest stop")
    func zoomOutEndsAtFit() {
        var viewport = Viewport(scale: 1)
        var scales: [Double?] = []
        while viewport.canZoomOut(photo: photo, view: view) {
            viewport = viewport.zoomedOut(photo: photo, view: view)
            scales.append(viewport.scale)
        }
        #expect(scales == [0.5, 0.25, nil])
    }

    @Test("For a small photo Fit falls between the steps, and smaller steps show it smaller than the view")
    func fitBetweenSteps() {
        let small = CGSize(width: 1500, height: 1000)
        #expect(Viewport.fitScale(photo: small, view: view) == 4.0 / 3)
        #expect(Viewport().zoomedIn(photo: small, view: view).scale == 2)
        #expect(Viewport().zoomedOut(photo: small, view: view).scale == 1)
        #expect(Viewport(scale: 1).zoomedIn(photo: small, view: view).isFit)
    }

    @Test("A pinched scale zooms in and out to the nearest step on either side")
    func freeScaleSteps() {
        let pinched = Viewport(scale: 0.7)
        #expect(pinched.zoomedIn(photo: photo, view: view).scale == 1)
        #expect(pinched.zoomedOut(photo: photo, view: view).scale == 0.5)
    }

    // MARK: Placement

    @Test("Fit centers the whole photo, and the whole photo is visible")
    func fitFrame() {
        let frame = Viewport().frame(photo: photo, view: view)
        #expect(abs(frame.width - 2000) < 0.001)
        #expect(frame.minX == 0)
        #expect(frame.minY == ((1400 - frame.height) / 2).rounded())
        #expect(Viewport().visibleRegion(photo: photo, view: view) == CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @Test("At 100% the view shows its own size in photo pixels, from a whole-pixel origin")
    func actualSizeRegion() {
        let viewport = Viewport(scale: 1, center: CGPoint(x: 0.5, y: 0.5))
        let frame = viewport.frame(photo: photo, view: view)
        #expect(frame.size == photo)
        #expect(frame.minX == frame.minX.rounded() && frame.minY == frame.minY.rounded())
        let region = viewport.visibleRegion(photo: photo, view: view)
        #expect(abs(region.width * photo.width - view.width) < 0.001)
        #expect(abs(region.height * photo.height - view.height) < 0.001)
        #expect(abs(region.midX - 0.5) < 0.001 && abs(region.midY - 0.5) < 0.001)
    }

    @Test("Zooming around a point keeps the photo point under it in place")
    func zoomAroundPoint() {
        let point = CGPoint(x: 1500, y: 400)
        let before = Viewport(scale: 0.5, center: CGPoint(x: 0.5, y: 0.5))
        let under = before.photoPoint(at: point, photo: photo, view: view)
        let after = before.zoomed(to: 2, keeping: point, photo: photo, view: view)
        let stillUnder = after.photoPoint(at: point, photo: photo, view: view)
        #expect(after.scale == 2)
        #expect(abs(under!.x - stillUnder!.x) * photo.width < 1)
        #expect(abs(under!.y - stillUnder!.y) * photo.height < 1)
    }

    @Test("Double-clicking Fit at a point zooms to 100% with that point under the pointer")
    func zoomFromFit() {
        let point = CGPoint(x: 1600, y: 700)
        let under = Viewport().photoPoint(at: point, photo: photo, view: view)!
        let after = Viewport().zoomed(to: 1, keeping: point, photo: photo, view: view)
        let stillUnder = after.photoPoint(at: point, photo: photo, view: view)!
        #expect(abs(under.x - stillUnder.x) * photo.width < 1)
        #expect(abs(under.y - stillUnder.y) * photo.height < 1)
    }

    @Test("Zooming near an edge stops at the edge, so no canvas shows past the photo")
    func zoomClampsToEdge() {
        // Above the photo, in the margin Fit leaves.
        let after = Viewport().zoomed(to: 1, keeping: CGPoint(x: 1000, y: 5), photo: photo, view: view)
        #expect(after.frame(photo: photo, view: view).minY == 0)
        #expect(after.visibleRegion(photo: photo, view: view).minY == 0)
    }

    @Test("Pinching is kept within 25% and 400%, and a scale of nil returns to Fit")
    func pinchLimits() {
        let center = CGPoint(x: 1000, y: 700)
        #expect(Viewport(scale: 1).zoomed(to: 9, keeping: center, photo: photo, view: view).scale == 4)
        #expect(Viewport(scale: 1).zoomed(to: 0.01, keeping: center, photo: photo, view: view).scale == 0.25)
        #expect(Viewport(scale: 1).zoomed(to: nil, keeping: center, photo: photo, view: view) == Viewport())
    }

    @Test("Panning moves the photo with the drag and stops at its edges")
    func panning() {
        let start = Viewport(scale: 1)
        let moved = start.panned(by: CGVector(dx: 100, dy: -50), photo: photo, view: view)
        let before = start.frame(photo: photo, view: view)
        let after = moved.frame(photo: photo, view: view)
        #expect(after.minX - before.minX == 100)
        #expect(after.minY - before.minY == -50)
        let far = start.panned(by: CGVector(dx: 100_000, dy: 100_000), photo: photo, view: view)
        #expect(far.frame(photo: photo, view: view).origin == .zero)
    }

    @Test("A photo smaller than the view stays centered and can't be panned")
    func smallerThanView() {
        let wide = CGSize(width: 3000, height: 2000)
        let viewport = Viewport(scale: 0.25, center: CGPoint(x: 0.9, y: 0.1)).clamped(photo: photo, view: wide)
        #expect(viewport.center == CGPoint(x: 0.5, y: 0.5))
        #expect(!viewport.canPan(photo: photo, view: wide))
        #expect(Viewport(scale: 1).canPan(photo: photo, view: view))
    }
}
