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
}
