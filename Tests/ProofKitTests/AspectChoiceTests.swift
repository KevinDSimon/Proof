import Testing
@testable import ProofKit

struct AspectChoiceTests {
    private let photo = AspectRatio(6000, 4000)

    @Test("An unlocked crop shows Freeform")
    func freeform() {
        #expect(AspectChoice.shown(for: nil, original: photo) == .freeform)
        #expect(AspectChoice.shown(for: nil, original: photo, choseCustom: true) == .freeform)
    }

    @Test("The photo's own shape shows Original in either orientation, ahead of a matching preset")
    func originalShape() {
        #expect(AspectChoice.shown(for: AspectRatio(6000, 4000), original: photo) == .original)
        #expect(AspectChoice.shown(for: AspectRatio(4000, 6000), original: photo) == .original)
        // 3:2 is also a preset; Original wins, as the menu shows one checkmark.
        #expect(AspectChoice.shown(for: AspectRatio(3, 2), original: photo) == .original)
    }

    @Test("A preset's shape shows that preset in either orientation")
    func presets() {
        #expect(AspectChoice.shown(for: AspectRatio(1, 1), original: photo) == .square)
        #expect(AspectChoice.shown(for: AspectRatio(5, 4), original: photo) == .fourFive)
        #expect(AspectChoice.shown(for: AspectRatio(9, 16), original: photo) == .sixteenNine)
        #expect(AspectChoice.shown(for: AspectRatio(3, 2), original: nil) == .threeTwo)
    }

    @Test("Any other shape, or one picked as Custom, shows Custom")
    func custom() {
        #expect(AspectChoice.shown(for: AspectRatio(2.35, 1), original: photo) == .custom)
        #expect(AspectChoice.shown(for: AspectRatio(1, 1), original: photo, choseCustom: true) == .custom)
    }

    @Test("Only the presets have a fixed shape")
    func ratios() {
        #expect(AspectChoice.allCases.filter { $0.ratio != nil } == [.square, .fourFive, .fiveSeven, .threeTwo, .sixteenNine])
    }
}
