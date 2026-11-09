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
