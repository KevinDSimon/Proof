import CoreGraphics
import Foundation
import Testing
@testable import ProofKit

struct HorizonTests {
    @Test("A line drawn level or upright needs no correction")
    func levelLine() throws {
        #expect(try #require(Horizon.correction(from: CGPoint(x: 10, y: 50), to: CGPoint(x: 200, y: 50))) == 0)
        #expect(try #require(Horizon.correction(from: CGPoint(x: 200, y: 50), to: CGPoint(x: 10, y: 50))) == 0)
        #expect(try #require(Horizon.correction(from: CGPoint(x: 40, y: 10), to: CGPoint(x: 40, y: 300))) == 0)
    }

    @Test("A line falling to the right is leveled by turning the photo counterclockwise")
    func fallingLine() throws {
        // On screen, with y downward: 5° below level toward the right.
        let radians = 5 * Double.pi / 180
        let end = CGPoint(x: 100 * cos(radians), y: 100 * sin(radians))
        let correction = try #require(Horizon.correction(from: .zero, to: end))
        #expect(abs(correction - -5) < 1e-9)
        // Drawn the other way along the same line, the correction is the same.
        let reversed = try #require(Horizon.correction(from: end, to: .zero))
        #expect(abs(reversed - -5) < 1e-9)
    }

    @Test("A line closer to vertical is made upright rather than level")
    func nearlyUprightLine() throws {
        // Leaning 3° clockwise from upright: down the screen and slightly left.
        let radians = 93 * Double.pi / 180
        let end = CGPoint(x: 100 * cos(radians), y: 100 * sin(radians))
        let correction = try #require(Horizon.correction(from: .zero, to: end))
        #expect(abs(correction - -3) < 1e-9)
    }

    @Test("Points too close together give no angle")
    func shortLine() {
        #expect(Horizon.correction(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 5.5, y: 5)) == nil)
        #expect(Horizon.correction(from: .zero, to: CGPoint(x: 8, y: 2), minimumLength: 10) == nil)
    }

    @Test("Dragging outside a corner turns the photo the way the pointer goes around the center")
    func cornerTurn() {
        let center = CGPoint(x: 100, y: 100)
        // From the right of the center to straight below it: a quarter turn clockwise on screen.
        #expect(abs(Horizon.turn(around: center, from: CGPoint(x: 200, y: 100), to: CGPoint(x: 100, y: 200)) - 90) < 1e-9)
        // Down a little from the top right corner: a small clockwise turn.
        let small = Horizon.turn(around: center, from: CGPoint(x: 200, y: 0), to: CGPoint(x: 200, y: 10))
        #expect(small > 0 && small < 10)
        // Across the left side, where the angle wraps, the turn stays small.
        let wrapped = Horizon.turn(around: center, from: CGPoint(x: 0, y: 101), to: CGPoint(x: 0, y: 99))
        #expect(abs(wrapped - 1.1459) < 1e-3)
    }

    @Test("Vision levels a landscape whose horizon is tilted by a known angle", arguments: [6.0, -4.0])
    func detectedHorizon(tilt: Double) async throws {
        let image = try #require(Self.landscape(tilt: tilt))
        let correction = try #require(try await Horizon.correction(in: image))
        // Rising to the right is a counterclockwise tilt, leveled by turning clockwise.
        #expect(abs(correction - tilt) < 1)
    }

    @Test("Without a horizon, Vision gives no correction")
    func noHorizon() async throws {
        let image = try #require(Self.plain())
        #expect(try await Horizon.correction(in: image) == nil)
    }

    /// Sky above ground, divided by a straight horizon through the center tilted `tilt` degrees
    /// counterclockwise.
    static func landscape(tilt: Double, size: CGSize = CGSize(width: 1200, height: 800)) -> CGImage? {
        guard let context = bitmap(size) else { return nil }
        // Core Graphics has y upward, so a positive slope rises to the right on screen.
        context.setFillColor(CGColor(srgbRed: 0.55, green: 0.72, blue: 0.92, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        let slope = tan(tilt * .pi / 180)
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        let reach = size.width
        context.setFillColor(CGColor(srgbRed: 0.22, green: 0.28, blue: 0.16, alpha: 1))
        context.move(to: CGPoint(x: middle.x - reach, y: middle.y - reach * slope))
        context.addLine(to: CGPoint(x: middle.x + reach, y: middle.y + reach * slope))
        context.addLine(to: CGPoint(x: middle.x + reach, y: -size.height))
        context.addLine(to: CGPoint(x: middle.x - reach, y: -size.height))
        context.closePath()
        context.fillPath()
        return context.makeImage()
    }

    static func plain(size: CGSize = CGSize(width: 1200, height: 800)) -> CGImage? {
        guard let context = bitmap(size) else { return nil }
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        return context.makeImage()
    }

    private static func bitmap(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }
}
