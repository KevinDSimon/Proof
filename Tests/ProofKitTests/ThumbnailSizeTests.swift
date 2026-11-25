import CoreGraphics
import Testing
@testable import ProofKit

struct ThumbnailSizeTests {
    @Test("A pinch scales the size it started from")
    func pinchScales() {
        #expect(ThumbnailSize.mac.pinched(from: 160, by: 1.5) == 240)
        #expect(ThumbnailSize.touch.pinched(from: 100, by: 0.8) == 80)
    }

    @Test("A pinch stops at the smallest and largest sizes")
    func pinchStopsAtLimits() {
        #expect(ThumbnailSize.mac.pinched(from: 160, by: 10) == 360)
        #expect(ThumbnailSize.mac.pinched(from: 160, by: 0.1) == 80)
        #expect(ThumbnailSize.touch.pinched(from: 100, by: 10) == 300)
        #expect(ThumbnailSize.touch.pinched(from: 100, by: 0.1) == 60)
    }

    @Test("A size that isn't a number gives the standard size")
    func nonNumberGivesStandard() {
        #expect(ThumbnailSize.mac.clamped(.nan) == 160)
        #expect(ThumbnailSize.touch.clamped(.infinity) == 100)
    }
}
