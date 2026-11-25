import Foundation
import UniformTypeIdentifiers

/// What one folder holds: its subfolders and the RAW, JPEG and HEIC photos directly inside it, in
/// Finder's order, except that a RAW comes before a JPEG or HEIC of the same name (#157).
/// Subfolders are named but not read, so showing a folder tree costs one listing per visible folder,
/// which matters on a NAS.
public struct FolderContents: Equatable, Sendable {
    public var subfolders: [String]
    public var photos: [Photo]

    public struct Photo: Equatable, Sendable {
        public var name: String
        /// A `.proof` sidecar sits next to it.
        public var isEdited: Bool
        /// Rating, flag and label from XMP. `nil` until read: `read(at:)` reads sidecars, and
        /// `embeddedMetadata(of:)` reads photos that have none.
        public var metadata: PhotoMetadata?

        public init(name: String, isEdited: Bool, metadata: PhotoMetadata? = nil) {
            self.name = name
            self.isEdited = isEdited
            self.metadata = metadata
        }
    }

    public init(subfolders: [String], photos: [Photo]) {
        self.subfolders = subfolders
        self.photos = photos
    }

    /// Reads `url` without descending into subfolders. A saved location that is a single photo
    /// lists that photo. Hidden files and packages such as photo libraries are skipped.
    /// Photos with an XMP sidecar get their metadata from it; the others are left `nil`.
    /// Blocks on file I/O, so call it off the main thread.
    public static func read(at url: URL) throws -> FolderContents {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentTypeKey, .contentModificationDateKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isDirectory == true, values.isPackage != true else {
            guard isPhoto(values) else { return FolderContents(subfolders: [], photos: []) }
            let isEdited = FileManager.default.fileExists(atPath: EditRecipe.sidecarURL(for: url).path)
            let photo = Photo(name: url.lastPathComponent, isEdited: isEdited,
                              metadata: XMPSidecar.existing(for: url).flatMap(readSidecar))
            return FolderContents(subfolders: [], photos: [photo])
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let names = Set(entries.map(\.lastPathComponent))
        var sidecars: [String: [URL]] = [:]
        for entry in entries where entry.pathExtension.lowercased() == "xmp" {
            sidecars[entry.lastPathComponent.lowercased(), default: []].append(entry)
        }
        var subfolders: [String] = []
        var photos: [Photo] = []
        let rawNames = entries.map(\.lastPathComponent).filter(isRAW(name:))
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
            let name = entry.lastPathComponent
            if values.isDirectory == true {
                if values.isPackage != true { subfolders.append(name) }
            } else if isPhoto(values) {
                let keys = PhotoMetadata.sidecarKeys(for: name, besideRAW: hasRAW(named: name, among: rawNames))
                let candidates = keys.flatMap { sidecars[$0] ?? [] }
                photos.append(Photo(name: name, isEdited: names.contains(name + ".proof"),
                                    metadata: newestSidecar(of: candidates).flatMap(readSidecar)))
            }
        }
        let finderOrder = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        return FolderContents(
            subfolders: subfolders.sorted(by: finderOrder),
            photos: photos.sorted { photoOrder($0.name, $1.name) })
    }

    /// Fills in metadata read from the photos themselves, by photo name. A photo that already has
    /// metadata keeps it, so a rating changed while the folder was being read isn't overwritten.
    /// This listing, with the metadata `earlier` had for photos this listing has none for: XMP read
    /// from inside the photo, or a rating changed in Proof. Used when a folder is read again.
    public func keepingMetadata(from earlier: FolderContents?) -> FolderContents {
        guard let earlier else { return self }
        var kept = self
        kept.setMetadata(Dictionary(earlier.photos.compactMap { photo in photo.metadata.map { (photo.name, $0) } },
                                    uniquingKeysWith: { first, _ in first }))
        return kept
    }

    public mutating func setMetadata(_ metadata: [String: PhotoMetadata]) {
        for index in photos.indices where photos[index].metadata == nil {
            if let value = metadata[photos[index].name] { photos[index].metadata = value }
        }
    }

    /// Reads the XMP embedded in each photo, for photos without a sidecar, delivering results in
    /// small batches so a folder on a NAS fills in as it is read. A photo that can't be read is
    /// delivered as `PhotoMetadata.unrated`.
    public static func embeddedMetadata(of photos: [(name: String, url: URL)]) -> AsyncStream<[String: PhotoMetadata]> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                var batch: [String: PhotoMetadata] = [:]
                for photo in photos {
                    if Task.isCancelled { break }
                    batch[photo.name] = PhotoMetadata.embedded(in: photo.url) ?? .unrated
                    if batch.count == 16 {
                        continuation.yield(batch)
                        batch = [:]
                    }
                }
                if !batch.isEmpty { continuation.yield(batch) }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// When two apps have each left a sidecar, such as `IMG_1.xmp` and `IMG_1.DNG.xmp`, the one
    /// changed most recently is the one the person last worked in.
    static func newestSidecar(of urls: [URL]) -> URL? {
        urls.max { modified($0) < modified($1) }
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    private static func readSidecar(_ url: URL) -> PhotoMetadata? {
        (try? Data(contentsOf: url)).flatMap(PhotoMetadata.init(xmp:))
    }

    static func isRAW(_ values: URLResourceValues) -> Bool {
        values.contentType?.conforms(to: .rawImage) == true
    }

    /// The formats Proof lists: RAW, JPEG and HEIC. PNG and TIFF are left out (#157).
    static func isPhoto(_ values: URLResourceValues) -> Bool {
        values.contentType.map(isPhoto) ?? false
    }

    static func isPhoto(_ type: UTType) -> Bool {
        type.conforms(to: .rawImage) || type.conforms(to: .jpeg) || type.conforms(to: .heic) || type.conforms(to: .heif)
    }

    /// Whether a file named `name` is a RAW photo, judged by its extension. Only RAW photos open in
    /// Edit until #239.
    public static func isRAW(name: String) -> Bool {
        UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .rawImage) == true
    }

    /// Whether one of `rawNames`, other than `name` itself, has `name`'s name without its
    /// extension, ignoring case, as `IMG_0042.CR3` has for `IMG_0042.JPG`.
    static func hasRAW(named name: String, among rawNames: [String]) -> Bool {
        let base = (name as NSString).deletingPathExtension.lowercased()
        return rawNames.contains { $0 != name && ($0 as NSString).deletingPathExtension.lowercased() == base }
    }

    /// Finder's order by name without the extension, with a RAW before other files of the same
    /// name, so a RAW+JPEG pair sits together with the RAW first whatever the extensions.
    static func photoOrder(_ a: String, _ b: String) -> Bool {
        let (baseA, baseB) = ((a as NSString).deletingPathExtension, (b as NSString).deletingPathExtension)
        switch baseA.localizedStandardCompare(baseB) {
        case .orderedAscending: return true
        case .orderedDescending: return false
        case .orderedSame:
            let (rawA, rawB) = (isRAW(name: a), isRAW(name: b))
            if rawA != rawB { return rawA }
            return a.localizedStandardCompare(b) == .orderedAscending
        }
    }
}

/// Which photos the toolbar filter shows. Each part that is set narrows the photos further, so
/// Flagged and 4 Stars shows flagged photos with four stars.
public struct FilterCriteria: Equatable, Sendable {
    public var flag: PhotoMetadata.Flag?
    /// A star rating from 1 to 5.
    public var rating: Int?
    /// Whether `rating` also matches higher ratings.
    public var includesHigherRatings = false
    public var edits: Edits?

    /// Whether a photo has a Proof edit.
    public enum Edits: Sendable {
        case edited
        case unedited
    }

    public init(flag: PhotoMetadata.Flag? = nil, rating: Int? = nil, includesHigherRatings: Bool = false,
                edits: Edits? = nil) {
        self.flag = flag
        self.rating = rating
        self.includesHigherRatings = includesHigherRatings
        self.edits = edits
    }

    /// Set only by `narrowed(by:)`, when two criteria ask for different values of one part.
    public private(set) var matchesNothing = false

    public static let none = FilterCriteria()

    /// Nothing is narrowed: every photo passes.
    public var isEmpty: Bool { activeCount == 0 && !matchesNothing }

    /// A sidebar filter row's criteria narrowed further by the toolbar's: one set of criteria
    /// that a photo passes only if it would pass both. Merged into one rather than checked one
    /// after the other, so the rule that a rating leaves rejected photos out sees either side's
    /// flag: Rejected with 3 Stars shows rejected 3-star photos, whichever side sets which.
    /// Parts that can't both hold, such as Flagged and Rejected, match no photo.
    public func narrowed(by other: FilterCriteria) -> FilterCriteria {
        var merged = self
        merged.matchesNothing = matchesNothing || other.matchesNothing
        func combine<Value: Equatable>(_ mine: Value?, _ theirs: Value?) -> Value? {
            guard let mine, let theirs else { return mine ?? theirs }
            if mine != theirs { merged.matchesNothing = true }
            return mine
        }
        merged.flag = combine(flag, other.flag)
        merged.edits = combine(edits, other.edits)
        switch (rating, other.rating) {
        case (nil, _):
            merged.rating = other.rating
            merged.includesHigherRatings = other.includesHigherRatings
        case (_, nil):
            break
        case let (mine?, theirs?):
            switch (includesHigherRatings, other.includesHigherRatings) {
            case (true, true):
                merged.rating = max(mine, theirs)
            case (false, false):
                if mine != theirs { merged.matchesNothing = true }
            case (false, true):
                if mine < theirs { merged.matchesNothing = true }
            case (true, false):
                merged.rating = theirs
                merged.includesHigherRatings = false
                if theirs < mine { merged.matchesNothing = true }
            }
        }
        return merged
    }

    /// How many parts are set, from 0 to 3, which the toolbar button shows.
    public var activeCount: Int {
        [flag != nil, rating != nil, edits != nil].filter { $0 }.count
    }

    public func includes(_ photo: FolderContents.Photo) -> Bool {
        if matchesNothing { return false }
        let metadata = photo.metadata
        if let flag, (metadata?.flag ?? .unflagged) != flag { return false }
        if let rating {
            let stars = metadata?.rating ?? 0
            guard includesHigherRatings ? stars >= rating : stars == rating else { return false }
            // A rating leaves rejected photos out, unless the flag asks for them.
            if flag == nil, metadata?.flag == .rejected { return false }
        }
        if let edits, photo.isEdited != (edits == .edited) { return false }
        return true
    }

    /// The parts that are set, as the toolbar button names them: "Flagged · 4+ Stars · Edited".
    /// Empty when nothing is set.
    public var summary: String {
        var parts: [String] = []
        switch flag {
        case .flagged: parts.append("Flagged")
        case .unflagged: parts.append("Unflagged")
        case .rejected: parts.append("Rejected")
        case nil: break
        }
        if let rating {
            let more = includesHigherRatings && rating < 5 ? "+" : ""
            parts.append("\(rating)\(more) \(rating == 1 && more.isEmpty ? "Star" : "Stars")")
        }
        switch edits {
        case .edited: parts.append("Edited")
        case .unedited: parts.append("Unedited")
        case nil: break
        }
        return parts.joined(separator: " · ")
    }
}

/// A sidebar filter row: photos with one flag, an edit, or one exact star rating, across folders.
public enum PhotoFilter: String, CaseIterable, Codable, Sendable {
    case flagged
    case rejected
    case edited
    case fiveStars
    case fourStars
    case threeStars
    case twoStars
    case oneStar

    /// The exact number of stars a star row matches.
    public var rating: Int? {
        switch self {
        case .fiveStars: 5
        case .fourStars: 4
        case .threeStars: 3
        case .twoStars: 2
        case .oneStar: 1
        default: nil
        }
    }

    public var title: String {
        switch self {
        case .flagged: "Flagged"
        case .rejected: "Rejected"
        case .edited: "Edited"
        default: rating == 1 ? "1 Star" : "\(rating ?? 0) Stars"
        }
    }

    /// The same filter as toolbar criteria. A star row leaves rejected photos out.
    public var criteria: FilterCriteria {
        switch self {
        case .flagged: FilterCriteria(flag: .flagged)
        case .rejected: FilterCriteria(flag: .rejected)
        case .edited: FilterCriteria(edits: .edited)
        default: FilterCriteria(rating: rating)
        }
    }

    public func includes(_ photo: FolderContents.Photo) -> Bool {
        criteria.includes(photo)
    }

    /// How many of `photos` each row matches, counted in one pass.
    public static func counts(of photos: some Sequence<FolderContents.Photo>) -> [PhotoFilter: Int] {
        var counts = Dictionary(uniqueKeysWithValues: allCases.map { ($0, 0) })
        for photo in photos {
            for filter in allCases where filter.includes(photo) { counts[filter, default: 0] += 1 }
        }
        return counts
    }
}
