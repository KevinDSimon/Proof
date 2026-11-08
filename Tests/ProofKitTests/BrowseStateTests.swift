import Testing
@testable import ProofKit

struct BrowseStateTests {
    let photos = (1...7).map { FolderContents.Photo(name: "IMG_\($0).DNG", isEdited: false) }

    @Test("Edit needs a selected photo, and Done returns to Browse with the same photo selected")
    func editAndDone() {
        var state = BrowseState()
        state.edit()
        #expect(state.mode == .browsing)

        state.selectedPhoto = "IMG_3.DNG"
        state.edit()
        #expect(state.mode == .editing)

        state.finishEditing()
        #expect(state.mode == .browsing)
        #expect(state.selectedPhoto == "IMG_3.DNG")
    }

    @Test("A photo the filter hides is deselected, which leaves Edit")
    func keepOnlyShownPhotos() {
        var state = BrowseState(selectedPhoto: "IMG_3.DNG")
        state.edit()
        state.keep(only: photos)
        #expect(state.mode == .editing)

        state.keep(only: Array(photos.prefix(2)))
        #expect(state.selectedPhoto == nil)
        #expect(state.mode == .browsing)
    }

    @Test("The position counts from 1 among the shown photos")
    func position() {
        #expect(BrowseState(selectedPhoto: "IMG_3.DNG").position(in: photos) == 3)
        #expect(BrowseState(selectedPhoto: "other.DNG").position(in: photos) == nil)
        #expect(BrowseState().position(in: photos) == nil)
    }

    @Test("Arrow keys move through a grid of rows and stop at its edges")
    func moveInGrid() {
        // Three columns:  1 2 3 / 4 5 6 / 7
        var state = BrowseState()
        state.move(.down, in: photos, columns: 3)
        #expect(state.selectedPhoto == "IMG_1.DNG")

        state.move(.left, in: photos, columns: 3)
        #expect(state.selectedPhoto == "IMG_1.DNG")
        state.move(.up, in: photos, columns: 3)
        #expect(state.selectedPhoto == "IMG_1.DNG")

        state.move(.down, in: photos, columns: 3)
        #expect(state.selectedPhoto == "IMG_4.DNG")
        state.move(.right, in: photos, columns: 3)
        state.move(.right, in: photos, columns: 3)
        #expect(state.selectedPhoto == "IMG_6.DNG")
        state.move(.right, in: photos, columns: 3)
        #expect(state.selectedPhoto == "IMG_6.DNG")

        state.move(.down, in: photos, columns: 3)
        #expect(state.selectedPhoto == "IMG_6.DNG")
        state.move(.left, in: photos, columns: 3)
        state.move(.left, in: photos, columns: 3)
        state.move(.down, in: photos, columns: 3)
        #expect(state.selectedPhoto == "IMG_7.DNG")
    }

    @Test("In a single row, as in the filmstrip, left and right step through the photos and stop at the ends")
    func moveInSingleRow() {
        var state = BrowseState(selectedPhoto: "IMG_1.DNG")
        state.move(.left, in: photos, columns: photos.count)
        #expect(state.selectedPhoto == "IMG_1.DNG")
        state.move(.right, in: photos, columns: photos.count)
        #expect(state.selectedPhoto == "IMG_2.DNG")

        state.selectedPhoto = "IMG_7.DNG"
        state.move(.right, in: photos, columns: photos.count)
        #expect(state.selectedPhoto == "IMG_7.DNG")
        state.move(.left, in: photos, columns: photos.count)
        #expect(state.selectedPhoto == "IMG_6.DNG")
    }
}
