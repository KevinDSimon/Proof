import Testing
@testable import ProofKit

struct FoldedCardsTests {
    @Test("Cards start expanded")
    func startExpanded() {
        #expect(FoldedCards().isExpanded("Curve"))
    }

    @Test("A folded card is closed while it is on, and other cards are not")
    func foldedCardCloses() {
        var folded = FoldedCards()
        folded.setFolded("Curve", true)
        #expect(!folded.isExpanded("Curve", isOn: true))
        #expect(folded.isExpanded("Detail", isOn: true))
    }

    @Test("A card that is off is closed whether or not it is folded")
    func offCardCloses() {
        #expect(!FoldedCards().isExpanded("Curve", isOn: false))
    }

    @Test("Unfolding a card shows it again")
    func unfold() {
        var folded = FoldedCards(["Histogram", "Curve"])
        folded.setFolded("Curve", false)
        #expect(folded.isExpanded("Curve"))
        #expect(folded.titles == ["Histogram"])
    }
}
