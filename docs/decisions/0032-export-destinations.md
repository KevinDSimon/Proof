# 0032. Saved export destinations

Date: 2026-11-12
Status: Accepted

## Context
Decision 0031 had the export folder chosen each time, and one set of settings remembered between exports. Issue #162 asked for saved destinations: a folder and settings that can be picked instead of choosing a folder each time. Decision 0031 turned down presets because their names hide what the file will be. A destination is different: it is named after where the files go, and the sheet shows its folder and settings when it is picked.

## Decision
- An `ExportDestination` is a name, a grant for a folder and an `ExportSettings`. `ExportDestinations` in `ProofKit` keeps them in order of adding, as JSON in `export-destinations.json` beside `locations.json`. The folder grants are security-scoped bookmarks made and resolved by `FileAccess` (`folderBookmark(for:)`, `resolveFolderBookmark(_:)`), as for saved folders. Destinations aren't saved locations and don't appear in the sidebar.
- The Export sheet starts with an Export To picker: Choose Folder, which asks for a folder at export as before, then each destination. The row shares its name with File › Export To. Picking one fills in its settings and shows its folder; Export then goes straight to the folder, with no open panel. Choose Folder brings back the last settings used without a destination, which stay remembered as before.
- Changing a setting while a destination is picked marks it as edited. The export uses the changes; the destination keeps its saved settings until Update Destination is clicked.
- The Destinations menu at the bottom left of the sheet has Save as New Destination… (a folder, then a name, the folder's name by default), and for the picked destination Rename…, Change Folder… and Delete…. Deleting forgets the destination and leaves its folder and files alone.
- File › Export To and the right-click menu's Export To list the destinations and export the selected photos right away, without the sheet. The sheet opens on the last destination used.
- A destination whose folder moved or was renamed is followed, and its bookmark refreshed. When the folder can't be found, such as on a drive that isn't connected, the sheet says so and offers Choose Folder…; Export To opens the sheet on that destination instead of exporting.

## Consequences
- A folder that is used every time takes one menu choice to export to.
- Destinations are listed in the order they were added and can't be reordered.
- There is no destination for AirDrop, the Share menu or a service; those remain separate work.
