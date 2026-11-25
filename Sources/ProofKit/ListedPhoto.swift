import Foundation

/// Identifies a photo by its folder and file name, so photos with the same name in different
/// folders are told apart when All Photos shows them together.
public struct PhotoReference: Codable, Hashable, Sendable {
    public var folder: FileReference
    public var name: String

    public init(folder: FileReference, name: String) {
        self.folder = folder
        self.name = name
    }

    /// Only RAW photos open in Edit until #239; JPEG and HEIC photos can be browsed and rated.
    public var isEditable: Bool { FolderContents.isRAW(name: name) }
}

/// A photo as the grid and filmstrip show it: what was read of it and the folder it is in.
public struct ListedPhoto: Equatable, Identifiable, Sendable {
    public var folder: FileReference
    public var photo: FolderContents.Photo

    public init(folder: FileReference, photo: FolderContents.Photo) {
        self.folder = folder
        self.photo = photo
    }

    public var id: PhotoReference { PhotoReference(folder: folder, name: photo.name) }
    public var name: String { photo.name }

    /// The photos of one folder, in its order.
    public static func photos(of folder: FileReference, in contents: [FileReference: FolderContents]) -> [ListedPhoto] {
        (contents[folder]?.photos ?? []).map { ListedPhoto(folder: folder, photo: $0) }
    }

    /// Every photo under `root` that has been read, in sidebar order: a folder's own photos come
    /// before its subfolders', and subfolders follow in Finder's order. Folders not read yet are
    /// left out until they are.
    public static func photos(under root: FileReference, in contents: [FileReference: FolderContents]) -> [ListedPhoto] {
        guard let folder = contents[root] else { return [] }
        var result = photos(of: root, in: contents)
        for subfolder in folder.subfolders {
            let child = FileReference(locationID: root.locationID, relativePath: root.relativePath + [subfolder])
            result += photos(under: child, in: contents)
        }
        return result
    }
}

extension FilterCriteria {
    /// The photos that pass, in their order, with the photos in `kept` too. A photo is kept after
    /// its rating, flag or edit changes, so it doesn't vanish while it is being worked on.
    public func filter(_ photos: [ListedPhoto], keeping kept: Set<PhotoReference> = []) -> [ListedPhoto] {
        photos.filter { includes($0.photo) || kept.contains($0.id) }
    }
}

/// How a photo is marked as part of a stack: a RAW and the JPEG or HEIC of the same name beside it
/// (#157). An open stack shows every photo, side by side, as ordinary tiles; the first, the RAW,
/// also shows how many there are. A collapsed one shows only the first. Virtual copies (#137)
/// will join these stacks.
public enum StackMark: Equatable, Sendable {
    case first(count: Int)
    case member
}

extension StackMark {
    /// The stack marks of `photos`, in the order they are shown. A stack is a run of photos in one
    /// folder with the same name but for the extension, ignoring case, that begins with a RAW,
    /// as `FolderContents` orders them. A JPEG whose RAW is filtered out isn't marked.
    public static func marks(in photos: [ListedPhoto]) -> [PhotoReference: StackMark] {
        var marks: [PhotoReference: StackMark] = [:]
        var start = photos.startIndex
        while start < photos.endIndex {
            let key = stackKey(photos[start])
            var end = start + 1
            while end < photos.endIndex, stackKey(photos[end]) == key { end += 1 }
            if end - start > 1, photos[start].id.isEditable {
                marks[photos[start].id] = .first(count: end - start)
                for photo in photos[(start + 1)..<end] { marks[photo.id] = .member }
            }
            start = end
        }
        return marks
    }

    /// `photos` without the photos after the first in each stack that isn't in `open`, which are
    /// collapsed. `marks` are `marks(in: photos)`.
    public static func shown(_ photos: [ListedPhoto], marks: [PhotoReference: StackMark],
                             open: Set<PhotoReference>) -> [ListedPhoto] {
        var first: PhotoReference?
        return photos.filter { photo in
            switch marks[photo.id] {
            case .first:
                first = photo.id
                return true
            case .member:
                return first.map(open.contains) ?? true
            case nil:
                return true
            }
        }
    }

    /// The first photo of the stack `photo` is in, `photo` itself if it is the first, or `nil`
    /// when it isn't in one. `marks` are `marks(in: photos)`.
    public static func first(of photo: PhotoReference, in photos: [ListedPhoto],
                             marks: [PhotoReference: StackMark]) -> PhotoReference? {
        guard marks[photo] != nil, let index = photos.firstIndex(where: { $0.id == photo }) else { return nil }
        return photos[...index].last { if case .first = marks[$0.id] { true } else { false } }?.id
    }

    private static func stackKey(_ photo: ListedPhoto) -> PhotoReference {
        PhotoReference(folder: photo.folder, name: (photo.name as NSString).deletingPathExtension.lowercased())
    }
}
