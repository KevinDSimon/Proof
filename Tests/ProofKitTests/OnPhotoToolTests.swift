import CoreGraphics
import Testing
@testable import ProofKit

struct OnPhotoToolTests {
    /// One level guide from (100, 100) to (300, 100), in points on screen.
    private let level = [(CGPoint(x: 100, y: 100), CGPoint(x: 300, y: 100))]

    @Test("A pointer takes a guide's end within 10 points and its line within 6")
    func pointerGuideReach() {
        #expect(GuideReach.pointer.part(at: CGPoint(x: 108, y: 104), ends: level) == .end(index: 0, isStart: true))
        #expect(GuideReach.pointer.part(at: CGPoint(x: 200, y: 105), ends: level) == .line(index: 0))
        #expect(GuideReach.pointer.part(at: CGPoint(x: 200, y: 110), ends: level) == nil)
    }

    @Test("A finger takes a guide's end within 22 points and its line within 14")
    func touchGuideReach() {
        #expect(GuideReach.touch.part(at: CGPoint(x: 285, y: 110), ends: level) == .end(index: 0, isStart: false))
        #expect(GuideReach.touch.part(at: CGPoint(x: 200, y: 112), ends: level) == .line(index: 0))
        #expect(GuideReach.touch.part(at: CGPoint(x: 200, y: 116), ends: level) == nil)
    }

    @Test("A guide's end is taken before another guide's line it lies on")
    func endsBeforeLines() {
        // A vertical guide whose top end lies on the level guide's line.
        let ends = level + [(CGPoint(x: 200, y: 100), CGPoint(x: 200, y: 300))]
        #expect(GuideReach.touch.part(at: CGPoint(x: 203, y: 101), ends: ends) == .end(index: 1, isStart: true))
    }

    @Test("A finger's loupe sits centered above it, and below it only where there's no room above")
    func touchLoupe() {
        let loupe = CGSize(width: 132, height: 154), size = CGSize(width: 400, height: 800)
        let above = LoupePlacement.touch.center(showing: CGPoint(x: 200, y: 400), loupe: loupe, in: size)
        #expect(above == CGPoint(x: 200, y: 400 - 44 - 77))
        let below = LoupePlacement.touch.center(showing: CGPoint(x: 200, y: 100), loupe: loupe, in: size)
        #expect(below == CGPoint(x: 200, y: 100 + 44 + 77))
        // Kept within the tool's sides near an edge.
        let edge = LoupePlacement.touch.center(showing: CGPoint(x: 10, y: 400), loupe: loupe, in: size)
        #expect(edge.x == 66)
    }

    @Test("A pointer's loupe sits below and to the right, and flips near the far edges")
    func pointerLoupe() {
        let loupe = CGSize(width: 110, height: 132), size = CGSize(width: 400, height: 400)
        #expect(LoupePlacement.pointer.center(showing: CGPoint(x: 50, y: 50), loupe: loupe, in: size)
                == CGPoint(x: 50 + 24 + 55, y: 50 + 24 + 66))
        #expect(LoupePlacement.pointer.center(showing: CGPoint(x: 350, y: 350), loupe: loupe, in: size)
                == CGPoint(x: 350 - 24 - 55, y: 350 - 24 - 66))
    }
}
