# 0014. The LUT library

Date: 2026-11-10
Status: Accepted

## Context
Issue #23 lets the person choose a look from LUTs they have imported, with a preview of the current photo through each. `look.lut` in the edit recipe names the LUT by file name (see `edit-format.md`). Proof ships with no LUTs. Preparing a large LUT takes seconds in a debug build (see 0013), and the canvas, thumbnails and previews all need the prepared table.

## Decision
- The library is a folder in Proof's own Application Support, not a folder the person picks. Imported files are copied in, so the original can be moved or deleted and every edit keeps finding its LUT. Because the folder is inside Proof's container, it needs no grant and doesn't go through `FileAccess`; the file being imported is read once, with the access the Open dialog or the drop gives.
- A file is parsed before it is copied. One that fails isn't added, and the parser's message is shown.
- File names are never reused for other contents. A second file with a taken name is numbered ("Portra 2.cube"); importing the same file again adds nothing. Edits that name a LUT keep rendering the same way.
- `LUTLibrary` is an actor that prepares each LUT off the main thread once and keeps it, up to 512 MB, letting the least recently used go first. A 33-per-side LUT takes about 0.6 MB prepared, a 65-per-side one about 4.4 MB, and the largest, 128 per side, 32 MB.
- Previews render the photo once, small and without its look, and apply each LUT to that image at full strength. A LUT changes each pixel on its own, so this matches a full render with the look at that size, without decoding the RAW file again for every LUT.
- Folders are kept. Importing a folder copies its `.cube` files with the folder's name and subfolders, so a set such as Portra 160, 400 and 800 stays together. `look.lut` is the path inside the library, with `/` between folders. A LUT outside any folder is named by its file name alone, which is what edits saved before folders hold, so they render as before. Paths with an empty, hidden or `..` part are refused, since a path comes from a sidecar.
- The Looks section shows one folder at a time, chosen from a pop-up of the library's folders, as Pixelmator Pro picks a collection. A folder that holds other folders opens as a submenu; LUTs outside any folder are listed as Other. The pop-up also holds Add Looks… and Reveal in Finder, which opens the library's folder so LUTs can be renamed, moved or removed there; Proof reads the folder again when it becomes active. Showing one folder keeps the list short however large the library grows, and keeps sets such as Portra 160, 400 and 800 side by side for comparing.
- The shown folder's LUTs are a native `List` in the plain style, on the section's own background, with a small preview of the photo as each look's icon. The list's own selection and keyboard navigation choose the look, so Up and Down Arrow try looks in turn, and the selection highlight follows the app's black and gray accent. Photo › Next Look and Previous Look (Option-Command-] and [) do the same from anywhere in Edit. The folder follows the chosen look when a photo is opened.
- There is no None row: Reset removes the look, as Reset does for Curve, and a switch in the header shows the photo without its look to compare. Strength sits above the pop-up and the list, so choosing a look or another folder never moves it, and is disabled while no look is chosen. Choosing a look keeps the strength already set; the first look chosen starts at 100%.

## Consequences
- Removing or renaming LUTs and folders is done in the Finder, through Reveal in Finder. Files added there aren't checked by the parser until they are loaded; one that doesn't parse is skipped like a missing LUT. A LUT removed this way is skipped when an edit that names it renders, and the Looks section says it is missing.
- An edited thumbnail rendered while its LUT is missing is cached without the look until the edit changes.
- Previews are 8-bit before the LUT, which can show banding in smooth gradients at preview size. The canvas and export aren't affected.
