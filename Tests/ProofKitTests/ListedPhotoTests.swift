import Foundation
import Testing
@testable import ProofKit

struct ListedPhotoTests {
    let location = UUID()

    func folder(_ path: String...) -> FileReference {
        FileReference(locationID: location, relativePath: path)
    }

    func contents(subfolders: [String], photos: [String]) -> FolderContents {
        FolderContents(subfolders: subfolders, photos: photos.map { FolderContents.Photo(name: $0, isEdited: false) })
    }

    @Test("A tree lists a folder's own photos, then each subfolder's in order, and skips folders not read yet")
    func treeOrder() {
        let read: [FileReference: FolderContents] = [
            folder(): contents(subfolders: ["Albums", "Unread"], photos: ["root.DNG"]),
            folder("Albums"): contents(subfolders: ["Coast", "Desert"], photos: []),
            folder("Albums", "Coast"): contents(subfolders: [], photos: ["IMG_1.DNG", "IMG_2.DNG"]),
            folder("Albums", "Desert"): contents(subfolders: [], photos: ["IMG_1.DNG"]),
        ]
        let photos = ListedPhoto.photos(under: folder(), in: read)
        #expect(photos.map(\.name) == ["root.DNG", "IMG_1.DNG", "IMG_2.DNG", "IMG_1.DNG"])
        #expect(photos[1].folder == folder("Albums", "Coast"))
        #expect(photos[3].folder == folder("Albums", "Desert"))
        #expect(Set(photos.map(\.id)).count == 4)
    }

    @Test("A tree whose top folder hasn't been read has no photos yet")
    func unreadRoot() {
        #expect(ListedPhoto.photos(under: folder(), in: [:]).isEmpty)
    }

    func listed(_ name: String, rating: Int? = nil, flag: PhotoMetadata.Flag = .unflagged,
                isEdited: Bool = false) -> ListedPhoto {
        let metadata = rating == nil && flag == .unflagged ? nil : PhotoMetadata(rating: rating ?? 0, flag: flag)
        return ListedPhoto(folder: folder(), photo: FolderContents.Photo(name: name, isEdited: isEdited, metadata: metadata))
    }

    @Test("Edited and Unedited split the photos by whether they have an edit")
    func editsFilter() {
        let photos = [listed("a", isEdited: true), listed("b"), listed("c", rating: 3, isEdited: true)]
        #expect(FilterCriteria(edits: .edited).filter(photos).map(\.name) == ["a", "c"])
        #expect(FilterCriteria(edits: .unedited).filter(photos).map(\.name) == ["b"])
        #expect(FilterCriteria(rating: 3, edits: .unedited).filter(photos).isEmpty)
        #expect(FilterCriteria(edits: .unedited).summary == "Unedited")
    }

    @Test("A kept photo stays in its place in the filtered list after it stops matching")
    func keptPhoto() {
        let photos = [listed("a", flag: .flagged), listed("b"), listed("c", flag: .flagged)]
        let flagged = FilterCriteria(flag: .flagged)
        #expect(flagged.filter(photos).map(\.name) == ["a", "c"])
        #expect(flagged.filter(photos, keeping: [photos[1].id]).map(\.name) == ["a", "b", "c"])
    }

    @Test("Next and previous photo step through the filtered list, skipping photos that don't match")
    func filteredNavigation() {
        let photos = [listed("a", rating: 4), listed("b", rating: 2), listed("c"), listed("d", rating: 5)]
        let fourAndUp = FilterCriteria(rating: 4, includesHigherRatings: true).filter(photos)
        var browse = BrowseState()
        browse.selectedPhoto = photos[0].id
        browse.move(.right, in: fourAndUp, columns: fourAndUp.count)
        #expect(browse.selectedPhoto == photos[3].id)
        // The last photo is the end of the filmstrip.
        browse.move(.right, in: fourAndUp, columns: fourAndUp.count)
        #expect(browse.selectedPhoto == photos[3].id)
        browse.move(.left, in: fourAndUp, columns: fourAndUp.count)
        #expect(browse.selectedPhoto == photos[0].id)
    }
}
