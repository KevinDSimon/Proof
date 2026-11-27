# 0057. Thumbnail cache location and size limit

Date: 2026-11-26
Status: Accepted. Carries out the storage part of 0050.

## Context
Issue #251. The thumbnail cache was in Application Support on every platform and grew without bound: thumbnails of photos that were deleted, moved or edited many times stayed until the cache was deleted by hand. Decision 0050 says that on iOS the cache goes in Caches, with a size limit that removes the least recently used thumbnails first. The issue asks for the limit on the Mac too unless there's a reason not to.

## Decision
- **Location.** On iPad and iPhone the cache is in `Caches/Proof/Thumbnails`, which iOS doesn't back up and can clear when the device runs low on space. On the Mac it stays in `Application Support/Proof/Thumbnails`. Thumbnails already in Application Support on iOS aren't moved; Proof is not yet released on iOS, so there are none outside development builds.
- **Limit.** 500 MB on iOS and 2 GB on the Mac. A thumbnail is usually 50 KB to 300 KB, so that is several thousand photos on iOS and tens of thousands on the Mac. The Mac has the larger limit because it browses network shares, where making a thumbnail again costs a round trip to the share for each photo.
- **Least recently read.** Each stored thumbnail's modification date is set when it is read from the cache, and the thumbnails with the oldest dates are removed first. The file's access date would be the natural record, but APFS doesn't update it on every read. Setting the date is one small write on local disk per cache hit.
- **When.** Proof keeps an estimate of the cache's size in memory. The first thumbnail stored after launch measures the directory; each later one adds its size. When the estimate passes the limit, Proof measures the directory again and removes whole photo folders, oldest first, until the cache is under 90% of the limit, so it isn't trimmed again on the next store. This runs on the thread that stored the thumbnail, never on the main thread, and only one trim runs at a time.

## Consequences
- The cache no longer grows without bound on any platform, and iOS can reclaim it.
- A photo whose thumbnail was removed has it made again when it is next shown, from its embedded preview or, for an edited photo, a render.
- Measuring the directory reads the size and date of every stored thumbnail. With a full 2 GB cache on the Mac that is tens of thousands of file lookups on local disk, once after launch and again only when the limit is passed.
- The limits are fixed. A setting for them can be added later if people ask for one.
