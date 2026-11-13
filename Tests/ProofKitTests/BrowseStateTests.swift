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

    @Test("Deselecting in Browse clears every selected photo, and a later ⇧-click starts a new range")
    func deselectEverything() {
        var state = BrowseState(selectedPhoto: ref(2))
        state.selectAll(photos)
        state.selectedPhoto = nil
        #expect(state.selectedPhotos.isEmpty)
        #expect(state.mode == .browsing)

        state.extend(to: ref(5), in: photos)
        #expect(state.selectedPhotos == [ref(5)])
    }

    @Test("Backslash's original shows only in Edit, and ends when leaving the photo or Edit")
    func showOriginal() {
        var state = BrowseState(selectedPhoto: ref(3))
        state.toggleOriginal()
        #expect(!state.isShowingOriginal)

        state.edit()
        state.toggleOriginal()
        #expect(state.isShowingOriginal)
        state.toggleOriginal()
        #expect(!state.isShowingOriginal)

        state.toggleOriginal()
        state.selectedPhoto = ref(3)
        #expect(state.isShowingOriginal)
        state.selectedPhoto = ref(4)
        #expect(!state.isShowingOriginal)

        state.toggleOriginal()
        state.finishEditing()
        #expect(!state.isShowingOriginal)

        state.edit()
        state.toggleOriginal()
        state.showEdited()
        #expect(!state.isShowingOriginal)
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

    @Test("⌘-click adds and removes photos, keeping the photo Edit shows")
    func toggleSelection() {
        var state = BrowseState(selectedPhoto: ref(2))
        state.toggle(ref(5), in: photos)
        state.toggle(ref(4), in: photos)
        #expect(state.selectedPhotos == [ref(2), ref(4), ref(5)])
        #expect(state.selectedPhoto == ref(2))
        #expect(state.hasMultipleSelection)
        #expect(state.selected(in: photos) == [ref(2), ref(4), ref(5)])

        state.toggle(ref(4), in: photos)
        #expect(state.selectedPhotos == [ref(2), ref(5)])
    }

    @Test("Removing the photo Edit shows moves it to the nearest selected photo after it")
    func toggleOffPrimary() {
        var state = BrowseState(selectedPhoto: ref(3))
        state.edit()
        state.toggle(ref(1), in: photos)
        state.toggle(ref(6), in: photos)
        state.toggle(ref(3), in: photos)
        #expect(state.selectedPhoto == ref(6))
        state.toggle(ref(6), in: photos)
        #expect(state.selectedPhoto == ref(1))
        #expect(state.mode == .editing)

        state.toggle(ref(1), in: photos)
        #expect(state.selectedPhoto == nil)
        #expect(state.selectedPhotos.isEmpty)
        #expect(state.mode == .browsing)
    }

    @Test("⌘-click with nothing selected selects that photo")
    func toggleFromNothing() {
        var state = BrowseState()
        state.toggle(ref(4), in: photos)
        #expect(state.selectedPhoto == ref(4))
        #expect(state.selectedPhotos == [ref(4)])
    }

    @Test("⇧-click selects a range from the last click, and a second ⇧-click replaces the range")
    func extendSelection() {
        var state = BrowseState(selectedPhoto: ref(3))
        state.extend(to: ref(6), in: photos)
        #expect(state.selectedPhotos == [ref(3), ref(4), ref(5), ref(6)])
        #expect(state.selectedPhoto == ref(3))

        state.extend(to: ref(1), in: photos)
        #expect(state.selectedPhotos == [ref(1), ref(2), ref(3)])

        // A ⌘-click sets a new anchor; the next range adds to what was selected then.
        state.toggle(ref(6), in: photos)
        state.extend(to: ref(7), in: photos)
        #expect(state.selectedPhotos == [ref(1), ref(2), ref(3), ref(6), ref(7)])
    }

    @Test("⇧-click with nothing selected selects only that photo")
    func extendFromNothing() {
        var state = BrowseState()
        state.extend(to: ref(5), in: photos)
        #expect(state.selectedPhotos == [ref(5)])
        #expect(state.selectedPhoto == ref(5))
    }

    @Test("A plain click and the arrow keys select a single photo again")
    func singleSelectionAgain() {
        var state = BrowseState(selectedPhoto: ref(1))
        state.selectAll(photos)
        #expect(state.selectedPhotos.count == 7)
        #expect(state.selectedPhoto == ref(1))

        state.move(.right, in: photos, columns: 3)
        #expect(state.selectedPhotos == [ref(2)])

        state.selectAll(photos)
        state.selectedPhoto = ref(5)
        #expect(state.selectedPhotos == [ref(5)])

        state.selectAll(photos)
        state.selectOnlyCurrent()
        #expect(state.selectedPhotos == [ref(5)])
    }

    @Test("⌘A with nothing selected makes the first photo the one Edit shows")
    func selectAllFromNothing() {
        var state = BrowseState()
        state.selectAll(photos)
        #expect(state.selectedPhoto == ref(1))
        state.selectAll([])
        #expect(state.selectedPhotos.count == 7)
    }

    @Test("Photos the filter hides are deselected, and the first one left takes over Edit")
    func keepOnlyShownInSelection() {
        var state = BrowseState(selectedPhoto: ref(2))
        state.edit()
        state.toggle(ref(4), in: photos)
        state.toggle(ref(6), in: photos)
        state.keep(only: photos.filter { $0.id != ref(2) && $0.id != ref(6) })
        #expect(state.selectedPhotos == [ref(4)])
        #expect(state.selectedPhoto == ref(4))
        #expect(state.mode == .editing)
    }
}
