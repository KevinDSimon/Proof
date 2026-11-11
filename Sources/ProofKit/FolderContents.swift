import Foundation
import UniformTypeIdentifiers

/// What one folder holds: its subfolders and the RAW photos directly inside it, in Finder's order.
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
            guard isRAW(values) else { return FolderContents(subfolders: [], photos: []) }
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
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
            let name = entry.lastPathComponent
            if values.isDirectory == true {
                if values.isPackage != true { subfolders.append(name) }
            } else if isRAW(values) {
                let candidates = PhotoMetadata.sidecarKeys(for: name).flatMap { sidecars[$0] ?? [] }
                photos.append(Photo(name: name, isEdited: names.contains(name + ".proof"),
                                    metadata: newestSidecar(of: candidates).flatMap(readSidecar)))
            }
        }
        let finderOrder = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        return FolderContents(
            subfolders: subfolders.sorted(by: finderOrder),
            photos: photos.sorted { finderOrder($0.name, $1.name) })
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

    private static func isRAW(_ values: URLResourceValues) -> Bool {
        values.contentType?.conforms(to: .rawImage) == true
    }
}

/// The library filters shown above the photos.
public enum PhotoFilter: String, CaseIterable, Codable, Sendable {
    case all
    case fiveStars
    case edited

    public func includes(_ photo: FolderContents.Photo) -> Bool {
        switch self {
        case .all: true
        case .fiveStars: photo.metadata?.rating == 5 && photo.metadata?.flag != .rejected
        case .edited: photo.isEdited
        }
    }
}
