import Testing
@testable import ProofKit

struct ExportProgressTests {
    @Test("Several photos show the share of photos done")
    func severalPhotos() {
        let progress = ExportProgress(total: 4, finished: 1)
        #expect(progress.fraction == 0.25)
        #expect(progress.percent == 25)
    }

    @Test("One photo has no percentage, because its render can't report how far it has got")
    func onePhoto() {
        #expect(ExportProgress(total: 1, finished: 0).fraction == nil)
        #expect(ExportProgress(total: 1, finished: 0).percent == nil)
        #expect(ExportProgress(total: 0, finished: 0).percent == nil)
    }

    @Test("The percentage rounds down, so it reads 100% only when every photo is done")
    func roundsDown() {
        #expect(ExportProgress(total: 200, finished: 199).percent == 99)
        #expect(ExportProgress(total: 3, finished: 2).percent == 66)
        #expect(ExportProgress(total: 3, finished: 3).percent == 100)
    }

    @Test("The percentage only goes up as photos finish and ends at 100%")
    func onlyGoesUp() {
        let percents = (0...7).compactMap { ExportProgress(total: 7, finished: $0).percent }
        #expect(percents == percents.sorted())
        #expect(percents.first == 0)
        #expect(percents.last == 100)
    }
}
