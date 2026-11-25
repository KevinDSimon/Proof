import CoreGraphics
import Foundation
import QuickLookThumbnailing

/// Photos kept in iCloud that aren't on this device yet (decision 0050). Browsing shows the
/// system's thumbnail for them and never downloads them; opening one downloads that photo only.
public enum CloudDownload {
    /// Downloads the file at `url` through file coordination, as Files does when a file is
    /// opened, and returns when it is on the device. Returns false if it couldn't be downloaded.
    /// The download isn't cancelled if the caller stops waiting. Blocks a background thread.
    public static func download(_ url: URL) async -> Bool {
        await Task.detached(priority: .userInitiated) {
            var coordinationError: NSError?
            var isReadable = false
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { url in
                isReadable = isDownloaded(url)
            }
            return coordinationError == nil && isReadable
        }.value
    }

    /// True unless the file is in iCloud with no copy on this device. Reads only the file's
    /// attributes.
    public static func isDownloaded(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return !FolderContents.isInCloud(isUbiquitous: values?.isUbiquitousItem,
                                         status: values?.ubiquitousItemDownloadingStatus)
    }

    /// The thumbnail the system keeps for `url`, which for a file in iCloud comes from iCloud
    /// without downloading the file. `nil` if there is none.
    public static func systemThumbnail(of url: URL, maxPixelSize: Int) async -> CGImage? {
        let side = CGFloat(maxPixelSize)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side),
                                                   scale: 1, representationTypes: .thumbnail)
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}
