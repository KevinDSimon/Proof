import CoreGraphics
import Testing
@testable import ProofKit

struct MaskEditingTests {
    private let photoSize = CGSize(width: 600, height: 400)

    @Test("A pointer takes a pin within 8 points and a handle within 7; a finger takes either within 22")
    func reach() {
        #expect(MaskReach.pointer.pin == 8)
        #expect(MaskReach.pointer.handle == 7)
        #expect(MaskReach.touch.pin == 22)
        #expect(MaskReach.touch.handle == 22)
        #expect(MaskReach.nearest([9], within: MaskReach.pointer.pin) == nil)
        #expect(MaskReach.nearest([20], within: MaskReach.touch.pin) == 0)
    }

    @Test("The nearest target within reach wins, and the first one tried wins a tie")
    func nearest() {
        #expect(MaskReach.nearest([15, 5, 10], within: 22) == 1)
        #expect(MaskReach.nearest([6, 6, 6], within: 22) == 0)
        #expect(MaskReach.nearest([30, .infinity], within: 22) == nil)
    }

    @Test("Touch keeps a radial gradient's turning handle out of its height handle's reach")
    func turnOffset() {
        #expect(MaskReach.touch.turnOffset >= MaskReach.touch.handle * 2)
        #expect(MaskReach.pointer.turnOffset >= MaskReach.pointer.handle * 2)
    }

    @Test("Dragging a linear gradient's outer line moves only its end; its pin moves both")
    func linearMove() {
        let mask = Mask(.linear(LinearMask(start: CGPoint(x: 0.5, y: 0.2), end: CGPoint(x: 0.5, y: 0.6))))
        let from = CGPoint(x: 0.5, y: 0.6), to = CGPoint(x: 0.5, y: 0.8)
        guard case let .linear(end) = mask.moved(.linearEnd, from: from, to: to, photoSize: photoSize).shape,
              case let .linear(both) = mask.moved(.pin(0), from: from, to: to, photoSize: photoSize).shape
        else { Issue.record("Not a linear gradient"); return }
        #expect(end.start == CGPoint(x: 0.5, y: 0.2))
        #expect(abs(end.end.y - 0.8) < 1e-9)
        #expect(abs(both.start.y - 0.4) < 1e-9)
        #expect(abs(both.end.y - 0.8) < 1e-9)
    }

    @Test("Turning a linear gradient keeps its middle and its length in pixels")
    func linearTurn() {
        let mask = Mask(.linear(LinearMask(start: CGPoint(x: 0.5, y: 0.25), end: CGPoint(x: 0.5, y: 0.75))))
        // A quarter turn: from straight below the middle to straight left of it.
        let turned = mask.moved(.linearTurn, from: CGPoint(x: 0.5, y: 0.75), to: CGPoint(x: 0.25, y: 0.5),
                                photoSize: photoSize)
        guard case let .linear(gradient) = turned.shape else { Issue.record("Not a linear gradient"); return }
        #expect(abs((gradient.startX + gradient.endX) / 2 - 0.5) < 1e-9)
        #expect(abs((gradient.startY + gradient.endY) / 2 - 0.5) < 1e-9)
        let length = hypot((gradient.endX - gradient.startX) * 600, (gradient.endY - gradient.startY) * 400)
        #expect(abs(length - 200) < 1e-6)
        #expect(abs(gradient.startY - gradient.endY) < 1e-9)
    }

    @Test("Turning a radial gradient follows the handle, in 15° steps when snapping")
    func radialTurn() {
        let mask = Mask(.radial(RadialMask(center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.1)))
        // To the right of the center, a quarter turn clockwise; slightly below it with snapping.
        let right = mask.moved(.radialTurn, from: .zero, to: CGPoint(x: 0.8, y: 0.5), photoSize: photoSize)
        let snapped = mask.moved(.radialTurn, from: .zero, to: CGPoint(x: 0.8, y: 0.52), photoSize: photoSize,
                                 snapsAngle: true)
        guard case let .radial(a) = right.shape, case let .radial(b) = snapped.shape
        else { Issue.record("Not a radial gradient"); return }
        #expect(abs(a.angle - 90) < 1e-9)
        #expect(b.angle == 90)
    }

    @Test("Sizing a radial gradient sets its radius from the center, as a share of the long edge")
    func radialSize() {
        let mask = Mask(.radial(RadialMask(center: CGPoint(x: 0.5, y: 0.5), radiusX: 0.2, radiusY: 0.1)))
        let sized = mask.moved(.radialWidth, from: .zero, to: CGPoint(x: 0.8, y: 0.5), photoSize: photoSize)
        guard case let .radial(gradient) = sized.shape else { Issue.record("Not a radial gradient"); return }
        #expect(abs(gradient.radiusX - 0.3) < 1e-9)
        #expect(gradient.radiusY == 0.1)
    }

    @Test("Dragging a brush mask's pin moves every stroke with it; nothing else moves it")
    func brushMove() {
        let strokes = [BrushStroke(points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.2, y: 0.3)]),
                       BrushStroke(points: [CGPoint(x: 0.5, y: 0.5)], erases: true)]
        let mask = Mask(.brush(BrushMask(strokes: strokes)))
        let from = CGPoint(x: 0.1, y: 0.1), to = CGPoint(x: 0.2, y: 0.15)
        guard case let .brush(brush) = mask.moved(.pin(0), from: from, to: to, photoSize: photoSize).shape
        else { Issue.record("Not a brush mask"); return }
        #expect(zip(brush.strokes[0].points, [0.2, 0.15, 0.3, 0.35]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(zip(brush.strokes[1].points, [0.6, 0.55]).allSatisfy { abs($0 - $1) < 1e-9 })
        #expect(mask.moved(.radialInside, from: from, to: to, photoSize: photoSize) == mask)
    }
}
