# 0055. The iPhone photo viewer: a persistent filmstrip and a native toolbar

Date: 2026-11-26
Status: Accepted. Changes how 0054's editor is reached on iPhone.

## Context
Issue #286. Until now a tap in the iPhone grid opened the photo straight into `PhoneEditor` (decision 0054), with the filmstrip under the photo and five editing tools in the bottom toolbar. Decision 0051 makes the phone a place to browse, cull, rate and share as much as to edit, and Apple Photos shows the shape for that: a photo viewer with a filmstrip and a few actions, and Edit as a separate step.

## Decision
- **iPhone only.** A tap in the grid pushes `PhoneViewer` in the iOS app. iPad keeps `PhotoView` with its inspector, including in a narrow window.
- **The viewer** shows the photo with its edit on the canvas, as Edit does, with the standard Back button and the filename as the title. It uses the same `EditPhoto` canvas, so pinch zoom, double-tap, touch-and-hold for the original and the sideways swipe work as before. In the model it is Edit (`BrowseState.Mode.editing`), since that is the mode that opens a photo's edit.
- **Filmstrip.** The shared `Filmstrip` sits under the photo the whole time; it is the one custom view, as the Interface rules allow. A swipe on the photo and a tap on a thumbnail both move the selection, and the filmstrip scrolls the current photo to its middle, so the two stay in step. Its thumbnails come from the same cache at the same target size as the grid's; nothing about how they load or render changes.
- **Bottom toolbar.** Four `ToolbarItem`s with flexible `ToolbarSpacer`s between them, each its own Liquid Glass button: Share, Rating, Info and Edit. Share leads, as in Photos, and opens the export sheet from #234. Rating is a native `Menu` with the inline rating picker, written to the photo's XMP sidecar as the grid's Rating menu is; its star fills when the photo has a rating and VoiceOver reads the number of stars as its value. Info opens `PhotoInfoSheet` (#233). Edit pushes `PhoneEditor`, whose Back returns to the viewer.
- **Left out.** Flag has no button: the toolbar holds the four actions the issue names, and flags stay in the filmstrip's and grid's touch-and-hold menus and in Select. The viewer has no More menu.
- **The editor gives up the filmstrip.** It belonged to the viewer, so `PhoneEditor` shows only the photo above its tools, and the photo has the room. Crop's Straighten slider still sits below the photo. Compare is the editor's: going back to the viewer shows the edit again.
- **Keyboard tools.** A keyboard's shortcuts can still start Crop, Spot Removal or Masks while the viewer is up; the viewer then pushes the editor, where their controls and Done are.

## Consequences
- Opening a photo on iPhone takes one more tap to reach the tools, as in Photos, and rating, Info and Share are one tap from the photo.
- JPEG and HEIC photos reached from the filmstrip still show "Can't Edit This Photo Yet" until #239, now with Share and Edit turned off; they can be rated from the viewer.
- The viewer and the editor are both in Edit in the model, so Undo, Copy and Paste and the export queue work the same in both. The viewer presents Copy Settings and Export itself only while the editor isn't pushed.
