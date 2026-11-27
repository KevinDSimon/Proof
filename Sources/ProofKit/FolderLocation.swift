import Foundation

/// How the Files app on iPad and iPhone names a folder, such as "On My iPad › Proof Test", for
/// places where the folder's real path is inside a storage container and means nothing to the
/// person. The Mac shows the path itself.
public enum FolderLocation {
    /// The folder's name in the Files app: the place it's in, then the folders down to it, joined
    /// by "›". `deviceName` names the device's own storage, "On My iPad" or "On My iPhone".
    ///
    /// The place is read from the path, as the Files app keeps each place in a known folder:
    /// iCloud Drive in `Mobile Documents/com~apple~CloudDocs`, drives under `LiveFiles`, the
    /// device's own storage in a container's `File Provider Storage`. Any other path shows the
    /// folder's own name, which is what the Files app shows at the top of it.
    public static func filesName(of folder: URL, deviceName: String) -> String {
        let components = folder.standardizedFileURL.pathComponents
        func trail(after index: Int, in place: String?) -> String {
            let folders = Array(components[(index + 1)...])
            return ([place].compactMap { $0 } + folders).joined(separator: " › ")
        }

        if let index = components.firstIndex(of: "com~apple~CloudDocs"), index > 0,
           components[index - 1] == "Mobile Documents" {
            return trail(after: index, in: "iCloud Drive")
        }
        // Drives are at LiveFiles/<file system>/<drive name>; the Files app starts at the drive.
        if let index = components.firstIndex(of: "LiveFiles"), index + 2 < components.count {
            return trail(after: index + 1, in: nil)
        }
        if let index = components.lastIndex(of: "File Provider Storage") {
            return trail(after: index, in: deviceName)
        }
        return folder.lastPathComponent
    }
}
