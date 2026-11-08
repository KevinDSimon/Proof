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
        /// Stars from 0 to 5. `nil` until ratings are read from XMP.
        public var rating: Int?

        public init(name: String, isEdited: Bool, rating: Int? = nil) {
            self.name = name
            self.isEdited = isEdited
            self.rating = rating
        }
    }

    public init(subfolders: [String], photos: [Photo]) {
        self.subfolders = subfolders
        self.photos = photos
    }

    /// Reads `url` without descending into subfolders. A saved location that is a single photo
    /// lists that photo. Hidden files and packages such as photo libraries are skipped.
    /// Blocks on file I/O, so call it off the main thread.
    public static func read(at url: URL) throws -> FolderContents {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .contentTypeKey]
        let values = try url.resourceValues(forKeys: keys)
        guard values.isDirectory == true, values.isPackage != true else {
            let isEdited = FileManager.default.fileExists(atPath: EditRecipe.sidecarURL(for: url).path)
            let photos = isRAW(values) ? [Photo(name: url.lastPathComponent, isEdited: isEdited)] : []
            return FolderContents(subfolders: [], photos: photos)
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let names = Set(entries.map(\.lastPathComponent))
        var subfolders: [String] = []
        var photos: [Photo] = []
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: keys) else { continue }
            let name = entry.lastPathComponent
            if values.isDirectory == true {
                if values.isPackage != true { subfolders.append(name) }
            } else if isRAW(values) {
                photos.append(Photo(name: name, isEdited: names.contains(name + ".proof")))
            }
        }
        let finderOrder = { (a: String, b: String) in a.localizedStandardCompare(b) == .orderedAscending }
        return FolderContents(
            subfolders: subfolders.sorted(by: finderOrder),
            photos: photos.sorted { finderOrder($0.name, $1.name) })
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
        case .fiveStars: photo.rating == 5
        case .edited: photo.isEdited
        }
    }
}
