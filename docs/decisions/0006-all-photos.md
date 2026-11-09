# 0006. All Photos, the one view across folders

Date: 2026-11-09
Status: Accepted

## Context
Proof shows folders as they are on disk, one at a time. Issue #46 asks for a way to browse photos from every saved folder without opening each one. Photos are often kept in nested folders, such as Albums › Trip on a NAS, so a view that showed only the top level of each saved folder would leave most photos out. Reading a whole tree on a NAS is slow, and Proof otherwise reads a folder only when its sidebar row appears. Proof doesn't read capture dates yet.

## Decision
- An All Photos item sits above the saved folders in the sidebar. It is a view, not a folder: nothing on disk is moved, copied or grouped.
- It includes every RAW photo in each available saved folder and all of its subfolders.
- Photos are ordered by folder: saved folders in sidebar order, and within each, a folder's own photos (in Finder's order) before its subfolders' (in Finder's order), as the expanded sidebar would list them. Photos from one shoot stay together, and no extra file reads are needed.
- The tree is read only while All Photos is selected, one folder at a time in that order, so the grid fills in folder by folder. Folders the sidebar already read are not read again. Selecting something else stops the reading.
- Saved folders that are offline or missing are left out, and the subtitle names them.
- Photos are identified by folder and file name (`PhotoReference`), so two photos with the same name in different folders are told apart.

## Consequences
- The first time All Photos is opened on a large NAS tree, it takes as long as listing every folder. Ratings embedded in photos without sidecars are read after the listing, in the same order, so the 5 Stars filter fills in later than in a single folder.
- Thumbnails are loaded for every photo in All Photos, as in a folder, which on a large library means many first-time reads.
- Ordering by capture date would need the date read from every photo; it can be added later as a sort option without changing which photos are included.
