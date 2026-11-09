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

    @Test("Filters keep all photos, only 5-star photos that aren't rejected, or only edited photos")
    func filters() {
        let plain = FolderContents.Photo(name: "a", isEdited: false, metadata: .init(rating: 3))
        let edited = FolderContents.Photo(name: "b", isEdited: true)
        let fiveStar = FolderContents.Photo(name: "c", isEdited: false, metadata: .init(rating: 5))
        let rejected = FolderContents.Photo(name: "d", isEdited: false, metadata: .init(rating: 5, flag: .rejected))
        let photos = [plain, edited, fiveStar, rejected]

        #expect(photos.filter(PhotoFilter.all.includes) == photos)
        // A rejected photo stays out of 5 Stars even when it has five stars.
        #expect(photos.filter(PhotoFilter.fiveStars.includes) == [fiveStar])
        #expect(photos.filter(PhotoFilter.edited.includes) == [edited])
    }

    func sidecar(_ name: String, rating: Int, modified: Date = .now) throws {
        let url = root.appendingPathComponent(name)
        try Data(XMPSamples.rating(rating).utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }

    @Test("Ratings come from sidecars named the way Lightroom or darktable name them, in any case")
    func sidecarNames() throws {
        try make("A.DNG", "B.DNG", "C.CR3", "D.DNG")
        try sidecar("A.xmp", rating: 5)
        try sidecar("B.DNG.xmp", rating: 4)
        try sidecar("C.XMP", rating: 3)

        let photos = try FolderContents.read(at: root).photos
        #expect(photos.map(\.metadata?.rating) == [5, 4, 3, nil])
    }

    @Test("When a photo has two sidecars, the one changed last is used")
    func newestSidecarWins() throws {
        try make("A.DNG", "B.DNG")
        try sidecar("A.xmp", rating: 2, modified: .now.addingTimeInterval(-3600))
        try sidecar("A.DNG.xmp", rating: 5)
        try sidecar("B.xmp", rating: 1)
        try sidecar("B.DNG.xmp", rating: 4, modified: .now.addingTimeInterval(-3600))

        let photos = try FolderContents.read(at: root).photos
        #expect(photos.map(\.metadata?.rating) == [5, 1])
    }

    @Test("A saved location that is a single photo reads its sidecar")
    func singlePhotoSidecar() throws {
        try make("A.DNG")
        try sidecar("A.xmp", rating: 5)

        let contents = try FolderContents.read(at: root.appendingPathComponent("A.DNG"))
        #expect(contents.photos.first?.metadata?.rating == 5)
    }

    @Test("Photos without a sidecar get the metadata embedded in the file, and unreadable ones count as unrated")
    func embedded() async throws {
        try make("Broken.DNG")
        let tagged = root.appendingPathComponent("Tagged.tiff")
        try XMPSamples.writeImage(to: tagged, xmp: XMPSamples.rating(4))

        var contents = FolderContents(subfolders: [], photos: [.init(name: "Broken.DNG", isEdited: false),
                                                               .init(name: "Tagged.tiff", isEdited: false)])
        let urls = contents.photos.map { (name: $0.name, url: root.appendingPathComponent($0.name)) }
        for await batch in FolderContents.embeddedMetadata(of: urls) { contents.setMetadata(batch) }
        #expect(contents.photos.map(\.metadata) == [.unrated, .init(rating: 4)])
    }
}
