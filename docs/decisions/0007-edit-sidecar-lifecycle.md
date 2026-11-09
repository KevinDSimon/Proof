# 0007. When edit sidecars are created, reverted, relinked and reloaded

Date: 2026-11-09
Status: Accepted

## Context
Decision 0002 stores each edit in `<original file name>.proof` next to the original, and `docs/edit-format.md` defines its contents. Nothing writes the file yet. Before #11 starts saving edits, the file's life needs settling: when it appears and disappears, how someone removes an edit, what happens when the photo is renamed or moved outside Proof, and what happens when another device changes it. Writing sidecars (#11) and ratings to XMP (#52) both need read-write folder access, which saved folders don't have yet.

## Decision

### Creating and removing
- The sidecar is created on the first change that makes the edit differ from the original. Selecting a photo, or moving a slider and returning it to where it was before the file existed, writes nothing.
- When every value returns to neutral, through undo or by moving controls back, the sidecar is deleted. It holds nothing at that point, so it is removed directly rather than moved to the Trash. "Edited" therefore always means visibly edited.
- A sidecar that contains fields this version of Proof doesn't recognize is never treated as neutral and never auto-deleted.

### Revert to Original
- Photo › Revert to Original removes the edit immediately, without a confirmation dialog.
- The sidecar is moved to the Trash, so it can be recovered there as well.
- Revert is one undo step. Undo writes the edit back from memory as a new sidecar.

### Renamed, moved or deleted photos
- When Proof first writes a sidecar it also stores a fingerprint of the original: its size in bytes, its capture date and time including subseconds, and the camera's unique image ID when the file has one (`RawDataUniqueID` or `ImageUniqueID`). A rename doesn't change any of these.
- When Proof reads a folder and finds a sidecar with no photo of the same name, it looks for photos in that folder that have no sidecar of their own. If exactly one has the same fingerprint, Proof renames the sidecar to match it, using `NSFileCoordinator`. With no match, or more than one, it leaves the sidecar alone.
- Relinking only happens in folders Proof has read-write access to, and only within one folder. A photo moved to another folder without its sidecar loses its edit there; the sidecar stays in the old folder. Moving the photo and its `.proof` file together keeps the edit.
- A sidecar whose photo was deleted is ignored. Proof never shows or deletes it.

### Changes from another device or app
- When a photo's sidecar changes on disk while the photo is open, Proof reloads it and shows the new edit. In local folders the FSEvents watching from #10 notices this right away; in network folders it is noticed when Proof becomes the active app or on Refresh.
- The reload is one undo step, so undo returns to the edit that was showing before.
- Proof ignores the change notifications caused by its own writes, by comparing the file on disk with what it last wrote.
- There is no merging. The most recent write wins.

### Read-write access
- One read-write grant per saved folder covers both edit sidecars and XMP ratings. Whichever of #11 and #52 lands first switches the app to the read-write user-selected entitlement and read-write bookmarks.
- Folders saved before then keep working for browsing. The first time Proof needs to write into one, it asks the person to grant it again with an open panel pointed at that folder. Until they do, changes to photos in that folder stay in memory, and Proof says so.
- Originals are still never written to.

## Consequences
- The Edited filter and `isEdited` can keep checking whether a sidecar exists, with no need to read it.
- #11 adds the fingerprint to the edit format, which updates `docs/edit-format.md` and needs a migration test.
- A batch rename in Finder or another app keeps edits. A move to another folder keeps them only if the sidecars move too.
- Two devices editing the same photo at once overwrite each other; the last change wins, and the other device sees it on reload.
- People are asked to grant each saved folder once more, a single time, rather than once per feature.
