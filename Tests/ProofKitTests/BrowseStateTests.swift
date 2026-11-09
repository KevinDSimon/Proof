import Foundation
import Testing
@testable import ProofKit

struct BrowseStateTests {
    let folder = FileReference(locationID: UUID(), relativePath: ["Trip"])
    var photos: [ListedPhoto] {
        (1...7).map { ListedPhoto(folder: folder, photo: FolderContents.Photo(name: "IMG_\($0).DNG", isEdited: false)) }
    }

    func ref(_ number: Int) -> PhotoReference {
        PhotoReference(folder: folder, name: "IMG_\(number).DNG")
    }

    @Test("Edit needs a selected photo, and Done returns to Browse with the same photo selected")
    func editAndDone() {
        var state = BrowseState()
        state.edit()
        #expect(state.mode == .browsing)

        state.selectedPhoto = ref(3)
        state.edit()
        #expect(state.mode == .editing)

        state.finishEditing()
        #expect(state.mode == .browsing)
        #expect(state.selectedPhoto == ref(3))
    }

    @Test("A photo the filter hides is deselected, which leaves Edit")
    func keepOnlyShownPhotos() {
        var state = BrowseState(selectedPhoto: ref(3))
        state.edit()
        state.keep(only: photos)
        #expect(state.mode == .editing)

        state.keep(only: Array(photos.prefix(2)))
        #expect(state.selectedPhoto == nil)
        #expect(state.mode == .browsing)
    }

    @Test("The position counts from 1 among the shown photos")
    func position() {
        #expect(BrowseState(selectedPhoto: ref(3)).position(in: photos) == 3)
        #expect(BrowseState(selectedPhoto: PhotoReference(folder: folder, name: "other.DNG")).position(in: photos) == nil)
        #expect(BrowseState().position(in: photos) == nil)
    }

    @Test("Arrow keys move through a grid of rows and stop at its edges")
    func moveInGrid() {
        // Three columns:  1 2 3 / 4 5 6 / 7
        var state = BrowseState()
        state.move(.down, in: photos, columns: 3)
        #expect(state.selectedPhoto == ref(1))

        state.move(.left, in: photos, columns: 3)
        #expect(state.selectedPhoto == ref(1))
        state.move(.up, in: photos, columns: 3)
        #expect(state.selectedPhoto == ref(1))

        state.move(.down, in: photos, columns: 3)
        #expect(state.selectedPhoto == ref(4))
        state.move(.right, in: photos, columns: 3)
        state.move(.right, in: photos, columns: 3)
        #expect(state.selectedPhoto == ref(6))
        state.move(.right, in: photos, columns: 3)
        #expect(state.selectedPhoto == ref(6))

        state.move(.down, in: photos, columns: 3)
        #expect(state.selectedPhoto == ref(6))
        state.move(.left, in: photos, columns: 3)
        state.move(.left, in: photos, columns: 3)
        state.move(.down, in: photos, columns: 3)
        #expect(state.selectedPhoto == ref(7))
    }

    @Test("In a single row, as in the filmstrip, left and right step through the photos and stop at the ends")
    func moveInSingleRow() {
        var state = BrowseState(selectedPhoto: ref(1))
        state.move(.left, in: photos, columns: photos.count)
        #expect(state.selectedPhoto == ref(1))
        state.move(.right, in: photos, columns: photos.count)
        #expect(state.selectedPhoto == ref(2))

        state.selectedPhoto = ref(7)
        state.move(.right, in: photos, columns: photos.count)
        #expect(state.selectedPhoto == ref(7))
        state.move(.left, in: photos, columns: photos.count)
        #expect(state.selectedPhoto == ref(6))
    }

    @Test("Photos with the same name in different folders are told apart")
    func sameNameInTwoFolders() {
        let other = FileReference(locationID: folder.locationID, relativePath: ["Other"])
        let twin = ListedPhoto(folder: other, photo: FolderContents.Photo(name: "IMG_1.DNG", isEdited: false))
        let shown = [photos[0], twin]
        var state = BrowseState(selectedPhoto: twin.id)
        #expect(state.position(in: shown) == 2)
        state.move(.left, in: shown, columns: 2)
        #expect(state.selectedPhoto == ref(1))
        state.keep(only: [twin])
        #expect(state.selectedPhoto == nil)
    }
}
