import Foundation
import Testing
@testable import ProofKit

struct FolderContentsTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolderContentsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func make(_ paths: String...) throws {
        for path in paths {
            let url = root.appendingPathComponent(path)
            if path.hasSuffix("/") {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            } else {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
                try Data("raw".utf8).write(to: url)
            }
        }
    }

    @Test("A folder lists its subfolders and RAW photos as they are on disk, in Finder's order")
    func listsAsOnDisk() throws {
        try make("Trip 10/", "Trip 2/", "Trip 2/inside.DNG",
                 "IMG_10.CR3", "IMG_2.DNG", "IMG_2.DNG.proof", "IMG_2.xmp", "notes.txt", "web.jpg", ".hidden.DNG")

        let contents = try FolderContents.read(at: root)
        #expect(contents.subfolders == ["Trip 2", "Trip 10"])
        #expect(contents.photos.map(\.name) == ["IMG_2.DNG", "IMG_10.CR3"])
    }

    @Test("A photo with a .proof sidecar next to it counts as edited")
    func edited() throws {
        try make("A.DNG", "A.DNG.proof", "B.DNG")

        let photos = try FolderContents.read(at: root).photos
        #expect(photos.map(\.isEdited) == [true, false])
    }

    @Test("A saved location that is a single photo lists that photo")
    func singlePhotoLocation() throws {
        try make("A.DNG", "A.DNG.proof")

        let contents = try FolderContents.read(at: root.appendingPathComponent("A.DNG"))
        #expect(contents == FolderContents(subfolders: [], photos: [.init(name: "A.DNG", isEdited: true)]))
    }

    @Test("Filters keep all photos, only 5-star photos, or only edited photos")
    func filters() {
        let plain = FolderContents.Photo(name: "a", isEdited: false, rating: 3)
        let edited = FolderContents.Photo(name: "b", isEdited: true)
        let fiveStar = FolderContents.Photo(name: "c", isEdited: false, rating: 5)
        let photos = [plain, edited, fiveStar]

        #expect(photos.filter(PhotoFilter.all.includes) == photos)
        #expect(photos.filter(PhotoFilter.fiveStars.includes) == [fiveStar])
        #expect(photos.filter(PhotoFilter.edited.includes) == [edited])
    }
}
