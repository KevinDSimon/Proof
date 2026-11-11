# 0022. Writing ratings and flags to XMP sidecars

Date: 2026-11-10
Status: Accepted

## Context
Decision 0002 said Proof reads ratings from XMP but doesn't write them, so culling stayed in Photomator. Issue #52 saves the stars and flag set in Proof so Photomator, Lightroom, Capture One and others see them. Decision 0005 describes how each app writes these tags: sidecar names, attribute or element form, `xmpDM:pick` and `xmpDM:good` for the flag, and -1 stars for a rejection in Bridge and darktable. A sidecar also holds tags Proof doesn't know about, such as Lightroom's develop settings, keywords and other apps' own data. This record supersedes the "don't write ratings" part of decision 0002; edits stay in `.proof` files as before.

## Decision
- Write to the sidecar Proof reads (decision 0005): the most recently modified of `IMG.xmp` and `IMG.DNG.xmp`, in any capitalization, under its name on disk. With no sidecar, create `IMG.xmp`, the name Photomator, Lightroom and Capture One use. Never write into the DNG or any other original.
- Change only `xmp:Rating` (0 to 5), `xmpDM:pick` (1 flagged, 0 unflagged, -1 rejected) and `xmpDM:good` (`True` flagged, `False` rejected, removed when unflagged). A rejected photo keeps its stars, as in Lightroom; `xmp:Rating` is not set to -1.
- Edit the sidecar as text rather than parse it and write it out again. Tags are found by namespace URI under whatever prefix the file binds, and changed where they are, as an attribute or an element. A missing tag is added to the first `rdf:Description`: as an element when that description holds its properties as elements (Photomator), otherwise as an attribute lined up with the others (Lightroom). A missing namespace is declared on the same description. Everything else in the file keeps its bytes.
- Read the result back before writing. If it doesn't give the intended rating and flag with the label unchanged, or the file isn't XMP, leave the file alone and report an error.
- A new sidecar holds the rating, the flag and the label, if the photo has one. The label is taken from the XMP embedded in the photo when needed, because the new sidecar takes the place of that XMP in other apps.
- Read and write with `NSFileCoordinator`, and write atomically. Writes run off the main thread, one after another, so quick changes land in order.
- Writing needs the folder's read-write grant (decision 0007). Without it, Proof asks once per folder; until it is granted, changes stay in memory, the Edit inspector says so, and they are saved when the folder is granted.

## Consequences
- Ratings and flags set in Proof show up in other apps without an export or sync step, and nothing else in their sidecars changes.
- Bridge and darktable, which read rejection only from -1 stars, don't see a photo rejected in Proof.
- A sidecar laid out in a way the text editor doesn't recognize, such as one with no `rdf:Description`, isn't changed; Proof shows an error instead.
- Labels aren't written, since Proof can't change them yet. Writing them later can use the same editor for `xmp:Label`.
