# 0008. A saved single photo becomes its folder

Date: 2026-11-09
Status: Accepted

## Context
Early builds let the person open one photo instead of a folder, and that choice was saved as a location of its own. Since the Folders panel (#6), Add Folder and Locate accept only folders, but locations saved before then are still single photos. They show in the sidebar as if they were folders, which doesn't match the rule to show folders as they are on disk. They also can't hold a sidecar: the App Sandbox gives access to exactly what the person chose, and writing a file beside a photo needs a grant to its folder. Issue #64 asked whether to show the photo's folder, as Lightroom does when a single photo is imported, or the photo itself with its edits kept in memory.

## Decision
- Proof shows and saves a single photo through its folder, as Lightroom does. Every saved location is a folder.
- A location that is still a single photo is converted the first time Proof needs to write an edit for it. The same one-time prompt as the read-write grant in decision 0007 opens the folder picker at the photo's folder, with Grant Access. Only that folder is accepted.
- After the grant, the location keeps its identifier and becomes the folder. The photo keeps its reference, so its edit and undo history stay attached. The sidebar shows the folder by its name and lists all of its photos.
- Until the person grants it, edits to the photo stay in memory, and the inspector says they aren't saved and offers Grant Access….
- Proof never treats a single-photo location as writable, even if its grant is read-write.

## Consequences
- New users never see this prompt; it only appears for locations saved by early builds.
- Granting a photo's folder shows the folder's other photos too, which the person didn't choose individually. This matches Lightroom and the rule to show folders as they are.
- Opening a single photo directly, such as by dropping it on Proof, would need the same folder grant if it is ever added.
