import Foundation
import Testing
@testable import ProofKit

struct CanvasColorTests {
    @Test("With nothing stored, the canvas is dark gray")
    func defaultsToDarkGray() {
        #expect(CanvasColor(stored: nil) == .darkGray)
        #expect(CanvasColor(stored: Data("not a color".utf8)) == .darkGray)
    }

    @Test("Dark Gray is the 13% gray the canvas has always had")
    func darkGrayIsThirteenPercent() {
        let gray = CanvasColor.darkGray.components
        #expect(gray.red == 0.13 && gray.green == 0.13 && gray.blue == 0.13)
    }

    @Test("Every choice, including a custom color, is remembered as it was stored", arguments: [
        CanvasColor.darkGray, .black, .middleGray, .white, .custom(red: 0.2, green: 0.4, blue: 0.6),
    ])
    func roundTrips(color: CanvasColor) {
        #expect(CanvasColor(stored: color.encoded) == color)
    }

    @Test("A custom color outside 0 to 1 is drawn clamped")
    func customIsClamped() {
        let color = CanvasColor.custom(red: -0.5, green: 1.5, blue: .nan).components
        #expect(color.red == 0 && color.green == 1 && color.blue == 0)
    }

    @Test("The menu lists the four presets in order, then Custom")
    func presetsInOrder() {
        #expect(CanvasColor.presets.map(\.title) == ["Dark Gray", "Black", "Middle Gray", "White"])
        #expect(CanvasColor.custom(red: 0, green: 0, blue: 0).title == "Custom…")
    }
}
