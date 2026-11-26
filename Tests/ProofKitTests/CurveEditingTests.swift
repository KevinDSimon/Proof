import Foundation
import Testing
@testable import ProofKit

struct CurveEditingTests {
    let straight = [CurvePoint(0, 0), CurvePoint(1, 1)]

    @Test("A point is added on the curve, so the curve doesn't change until it moves")
    func addsOnTheCurve() throws {
        let bent = [CurvePoint(0, 0), CurvePoint(0.5, 0.7), CurvePoint(1, 1)]
        let (points, index) = try #require(CurveEditing.adding(at: 0.25, to: bent))
        #expect(index == 1)
        #expect(points.count == 4)
        #expect(points[1].input == 0.25)
        #expect(abs(points[1].output - CurveEditing.rounded(CurveSpline(bent)(0.25))) < 1e-9)
    }

    @Test("No point is added at an end, next to another point, or past the most a curve can have")
    func refusesToAdd() {
        #expect(CurveEditing.adding(at: 0, to: straight) == nil)
        #expect(CurveEditing.adding(at: 1, to: straight) == nil)
        #expect(CurveEditing.adding(at: 0.005, to: straight) == nil)
        let full = (0..<ToneCurve.maximumPoints).map { CurvePoint(Double($0) / 15, Double($0) / 15) }
        #expect(CurveEditing.adding(at: 0.5, to: full) == nil)
    }

    @Test("A moved point stays between its neighbors and inside the graph")
    func clampsMovedPoint() {
        let points = [CurvePoint(0, 0), CurvePoint(0.4, 0.4), CurvePoint(0.6, 0.6), CurvePoint(1, 1)]
        let moved = CurveEditing.clamped(CurvePoint(0.9, 1.3), at: 1, in: points)
        #expect(moved == CurvePoint(0.59, 1))
        #expect(CurveEditing.clamped(CurvePoint(-0.2, 0.3), at: 0, in: points) == CurvePoint(0, 0.3))
    }

    @Test("Only points between the ends can be removed")
    func removesInnerPointsOnly() {
        let points = [CurvePoint(0, 0), CurvePoint(0.5, 0.6), CurvePoint(1, 1)]
        #expect(!CurveEditing.canRemove(at: 0, in: points))
        #expect(CurveEditing.canRemove(at: 1, in: points))
        #expect(!CurveEditing.canRemove(at: 2, in: points))
    }

    @Test("Two presses on the same target close together are a double press; a third starts over")
    func doublePress() {
        var press = DoublePress<Int>(interval: 0.35)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        let first = press.press(1, at: start)
        let second = press.press(1, at: start.addingTimeInterval(0.2))
        let third = press.press(1, at: start.addingTimeInterval(0.3))
        #expect(!first)
        #expect(second)
        #expect(!third)
    }

    @Test("Presses too far apart, on different targets, or after a drag aren't a double press")
    func notDoublePress() {
        var press = DoublePress<Int>(interval: 0.35)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        _ = press.press(1, at: start)
        let late = press.press(1, at: start.addingTimeInterval(0.5))
        let otherTarget = press.press(2, at: start.addingTimeInterval(0.6))
        press.cancel()
        let afterDrag = press.press(2, at: start.addingTimeInterval(0.7))
        #expect(!late)
        #expect(!otherTarget)
        #expect(!afterDrag)
    }
}
