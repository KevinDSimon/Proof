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

    @Test("Sidebar rows keep one flag, edited photos, or one exact rating that isn't rejected")
    func filters() {
        let plain = FolderContents.Photo(name: "a", isEdited: false, metadata: .init(rating: 3))
        let edited = FolderContents.Photo(name: "b", isEdited: true)
        let fiveStar = FolderContents.Photo(name: "c", isEdited: false, metadata: .init(rating: 5))
        let rejected = FolderContents.Photo(name: "d", isEdited: false, metadata: .init(rating: 5, flag: .rejected))
        let flagged = FolderContents.Photo(name: "e", isEdited: false, metadata: .init(rating: 4, flag: .flagged))
        let photos = [plain, edited, fiveStar, rejected, flagged]

        // A rejected photo stays out of 5 Stars even when it has five stars.
        #expect(photos.filter(PhotoFilter.fiveStars.includes) == [fiveStar])
        #expect(photos.filter(PhotoFilter.fourStars.includes) == [flagged])
        // Stars match exactly, not "at least".
        #expect(photos.filter(PhotoFilter.threeStars.includes) == [plain])
        #expect(photos.filter(PhotoFilter.oneStar.includes).isEmpty)
        #expect(photos.filter(PhotoFilter.edited.includes) == [edited])
        #expect(photos.filter(PhotoFilter.flagged.includes) == [flagged])
        #expect(photos.filter(PhotoFilter.rejected.includes) == [rejected])
    }

    @Test("Toolbar criteria combine: every part that is set must match")
    func combinedCriteria() {
        let flaggedFour = FolderContents.Photo(name: "a", isEdited: true, metadata: .init(rating: 4, flag: .flagged))
        let flaggedTwo = FolderContents.Photo(name: "b", isEdited: false, metadata: .init(rating: 2, flag: .flagged))
        let five = FolderContents.Photo(name: "c", isEdited: false, metadata: .init(rating: 5))
        let rejectedFive = FolderContents.Photo(name: "d", isEdited: false, metadata: .init(rating: 5, flag: .rejected))
        let unrated = FolderContents.Photo(name: "e", isEdited: false)
        let photos = [flaggedFour, flaggedTwo, five, rejectedFive, unrated]

        #expect(photos.filter(FilterCriteria.none.includes) == photos)
        #expect(photos.filter(FilterCriteria(flag: .flagged, rating: 4).includes) == [flaggedFour])
        #expect(photos.filter(FilterCriteria(rating: 4, includesHigherRatings: true).includes) == [flaggedFour, five])
        #expect(photos.filter(FilterCriteria(flag: .unflagged).includes) == [five, unrated])
        #expect(photos.filter(FilterCriteria(flag: .flagged, edits: .edited).includes) == [flaggedFour])
        // Asking for rejected photos with a rating keeps them.
        #expect(photos.filter(FilterCriteria(flag: .rejected, rating: 5).includes) == [rejectedFive])
    }

    @Test("Criteria name and count the parts that are set, in menu order")
    func criteriaSummary() {
        #expect(FilterCriteria.none.summary.isEmpty)
        #expect(FilterCriteria.none.activeCount == 0)
        #expect(FilterCriteria(flag: .unflagged, rating: 5, edits: .edited).activeCount == 3)
        #expect(FilterCriteria(flag: .flagged, rating: 4, includesHigherRatings: true, edits: .edited).summary
                == "Flagged · 4+ Stars · Edited")
        #expect(FilterCriteria(rating: 1).summary == "1 Star")
        // Five stars and higher is just five stars.
        #expect(FilterCriteria(rating: 5, includesHigherRatings: true).summary == "5 Stars")
    }

    @Test("Counts list every row, including those that match nothing")
    func filterCounts() {
        let photos = [
            FolderContents.Photo(name: "a", isEdited: true, metadata: .init(rating: 5)),
            FolderContents.Photo(name: "b", isEdited: false, metadata: .init(rating: 5, flag: .flagged)),
        ]
        let counts = PhotoFilter.counts(of: photos)

        #expect(Set(counts.keys) == Set(PhotoFilter.allCases))
        #expect(counts[.fiveStars] == 2 && counts[.edited] == 1 && counts[.flagged] == 1)
        #expect(counts[.rejected] == 0 && counts[.oneStar] == 0)
    }

    @Test("Row titles name stars in the singular for one")
    func filterTitles() {
        #expect(PhotoFilter.allCases.map(\.title)
                == ["Flagged", "Rejected", "Edited", "5 Stars", "4 Stars", "3 Stars", "2 Stars", "1 Star"])
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

    @Test("Metadata read from the photos fills in only photos that have none yet")
    func setMetadataKeepsExisting() {
        var contents = FolderContents(subfolders: [], photos: [
            .init(name: "A.DNG", isEdited: false, metadata: .init(rating: 2)),
            .init(name: "B.DNG", isEdited: false)])
        contents.setMetadata(["A.DNG": .init(rating: 5), "B.DNG": .init(rating: 4)])
        #expect(contents.photos.map(\.metadata?.rating) == [2, 4])
    }

    @Test("Reading a folder again keeps metadata it can't read again, and takes what it can")
    func keepsMetadataWhenReadAgain() {
        let earlier = FolderContents(subfolders: [], photos: [
            .init(name: "A.DNG", isEdited: false, metadata: .init(rating: 3)),
            .init(name: "B.DNG", isEdited: false, metadata: .init(rating: 2)),
            .init(name: "Gone.DNG", isEdited: false, metadata: .init(rating: 5))])
        let reread = FolderContents(subfolders: [], photos: [
            .init(name: "A.DNG", isEdited: false),
            .init(name: "B.DNG", isEdited: false, metadata: .init(rating: 4)),
            .init(name: "New.DNG", isEdited: false)])
        let kept = reread.keepingMetadata(from: earlier)
        #expect(kept.photos.map(\.name) == ["A.DNG", "B.DNG", "New.DNG"])
        #expect(kept.photos.map(\.metadata?.rating) == [3, 4, nil])
    }
}
