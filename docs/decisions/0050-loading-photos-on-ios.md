# 0050. Loading photos on iPad and iPhone without downloading the library

Date: 2026-11-25
Status: Accepted. Extends 0048.

## Context
Decision 0048 lets the iPad and iPhone app open folders from Files, including iCloud Drive, where a file may be in the cloud with no copy on the device. A RAW is 20 to 60 MB. A folder of a few thousand photos would fill a phone if browsing downloaded them, and would take minutes on a cellular connection.

Today `ThumbnailCache` makes a thumbnail by opening the photo file. For an iCloud file that isn't on the device, that read either fails or makes iOS download the whole file. So browsing an iCloud folder could download every photo in it. The cache also lives in Application Support, which iOS backs up and never clears.

Lightroom and Photos solve this the same way: thumbnails come from previews kept apart from the originals, and an original is fetched only when it is edited or exported.

## Decision
- **Browsing never reads a full original.** A thumbnail comes from the first of these that has it:
  1. Proof's thumbnail cache.
  2. For a file on the device, a USB or SD drive, or a network share: the preview embedded in the photo, read with ImageIO, which reads only the parts of the file it needs, not the whole file.
  3. For an iCloud file that isn't downloaded: the thumbnail the system keeps for it (`QLThumbnailGenerator`, which uses the file provider's thumbnail without downloading the file). The cell shows a cloud badge.
  If none is available, the cell shows the cloud badge on a plain placeholder. It never starts a download.
- **Opening a photo downloads that photo only.** Opening a photo that isn't downloaded starts its download through `NSFileCoordinator`, shows the thumbnail with download progress, and opens Edit when the file is ready. Proof also starts downloading the previous and next photo in the folder's order, and no others. Leaving the photo doesn't cancel a download that has started.
- **Edit is fast to show.** Edit shows the cached thumbnail or embedded preview at once, then the RAW rendered at the canvas's size. A full-size render happens only on export (CLAUDE.md). Memory limits on iPhone are #236.
- **Export** of a photo that isn't downloaded downloads it first, one photo at a time, with the export's progress.
- **Storage stays bounded.**
  - Proof never copies originals into its own storage. A downloaded iCloud file stays in iCloud Drive, where iOS can remove the download again when space runs low, and the person can with Remove Download in Files. Edits are in the sidecar, so they survive.
  - On iOS the thumbnail cache is in Caches, which iOS doesn't back up and can clear. It has a size limit; the least recently used thumbnails are removed first. On the Mac it stays in Application Support.
- Ratings, flags and the filter rows read sidecars, which are small. Reading a sidecar that isn't downloaded downloads only the sidecar.

## Consequences
- Browsing a large iCloud folder costs only thumbnails, about 100 KB to 300 KB each.
- A photo that has never been downloaded and has no system thumbnail shows a placeholder until it is opened.
- Swiping to the next photo in Edit is usually instant, because it was fetched while the previous one was open. Jumping further waits for a download.
- `ThumbnailCache` needs a way to tell a file that isn't downloaded (`ubiquitousItemDownloadingStatus`) from one it can read, and a second source for thumbnails. Tests cover that browsing never opens an original that isn't downloaded.
- The cloud badge and download in #247 follow this record. The cache's location and size limit are a separate issue.
