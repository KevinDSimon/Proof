import Foundation

/// Downloads a photo kept in iCloud that isn't on this device yet, as Files and Finder do when a
/// file is opened.
public enum CloudDownload {
    /// Asks the system to download the file at `url`, then waits until it has, checking every
    /// `interval`. Returns false if the download couldn't start or the task was cancelled.
    public static func download(_ url: URL, checkingEvery interval: Duration = .milliseconds(500)) async -> Bool {
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        } catch {
            return false
        }
        while !Task.isCancelled {
            if isDownloaded(url) { return true }
            try? await Task.sleep(for: interval)
        }
        return false
    }

    /// True unless the file is in iCloud with no copy on this device.
    public static func isDownloaded(_ url: URL) -> Bool {
        var url = url
        url.removeAllCachedResourceValues()
        let values = try? url.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        return !FolderContents.isInCloud(isUbiquitous: values?.isUbiquitousItem,
                                         status: values?.ubiquitousItemDownloadingStatus)
    }
}
