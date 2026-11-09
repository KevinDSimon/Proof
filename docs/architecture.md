# Architecture

Proof is split into a platform-neutral engine package, `ProofKit`, and thin app targets on top of it. The Mac app comes first; an iPad and iPhone app reuses `ProofKit` unchanged.

## Layers

| Layer | Owns | Never imports |
| --- | --- | --- |
| `ProofKit` | Edit recipe, render pipeline, sidecar and XMP reading, `.cube` parsing, thumbnails | AppKit, UIKit, SwiftUI |
| Mac app (`App/Proof.xcodeproj`) | Folders panel, filmstrip, inspector, canvas, export UI | — |
| iOS app (later) | The same panels for touch, Files-app folder picking | — |

The Mac app runs in the App Sandbox. Its project links `ProofKit` as a local Swift package, so a change to `ProofKit` is picked up by the next app build without a version bump. Until signing is set up in Phase 4, the app is signed to run locally only.

## Render pipeline

Every render starts from the original RAW file and applies the edit recipe in this order:

1. RAW decode in linear light with `CIRAWFilter`: exposure, white balance (temperature and tint), noise reduction, lens corrections
2. Tone: highlights and shadows, then contrast, whites, blacks and the tone curve baked together into one lookup per channel
3. Color: vibrance, saturation
4. LUT, applied with `CIColorCubeWithColorSpace` in display-referred Rec.709/sRGB and blended by strength
5. Layers (v1.2): each layer's mask and adjustments, blended in order with `CIBlendWithMask`
6. Crop, straighten, and the output transform to the display or export color space

`RAWRenderer` in `ProofKit` performs step 1 today. It is an actor, so decoding and GPU work run off the main thread. It opens a file once and renders it into a Metal texture scaled to fit a requested pixel size. It applies exposure, in stops, through `CIRAWFilter.exposure`. Its `CIContext` caches intermediate results, so after the first render at a given size, a change to a later stage such as exposure reuses the decoded RAW data instead of decoding it again. Opening another photo clears the cache, so GPU memory holds the intermediates of one photo at a time. Cached and uncached renders of the same settings produce the same pixels. The Mac app's canvas is an `MTKView` that draws the latest texture scaled to the window; on resize it keeps drawing the old texture until a render at the new size finishes. The canvas runs one render at a time and never discards one in flight: while the exposure slider is dragged faster than renders finish, each finished render is shown and the next starts from the slider's latest value.

A render request always carries a target size. Interactive renders use a reduced `scaleFactor` while a control is being dragged and full screen resolution on release. Only export renders at full sensor resolution.

## Files and data

| Data | Where it lives | Who writes it |
| --- | --- | --- |
| Original RAW | Its own folder | Never written |
| Ratings, flags and labels | XMP sidecar (`IMG_0001.xmp` or `IMG_0001.DNG.xmp`) or XMP embedded in the DNG | Other apps; Proof reads only |
| Edit recipe | `IMG_0001.DNG.proof` next to the original, JSON | Proof |
| Thumbnails, folder index | Application Support | Proof; disposable |

See [edit-format.md](edit-format.md) for the recipe format.

### Thumbnails

`ThumbnailCache` in `ProofKit` makes and stores thumbnails, 512 pixels on the long edge, as JPEG files in `Application Support/Proof/Thumbnails`. A thumbnail comes from the JPEG preview that the camera or DNG converter embedded in the RAW file, so the RAW data isn't decoded. Only a file without an embedded preview is decoded in full.

Each photo has a folder in the cache named from a hash of its path, and the thumbnail inside is named from a hash of the file's size and modification date. A file whose size or date changed misses the cache, and storing its new thumbnail removes the old one. The size and date are read from the file system on every lookup, because a `URL` keeps resource values it has already read. Thumbnails of photos that were deleted or moved stay in the cache until it is cleared; the cache can be deleted at any time.

For a folder, cached thumbnails arrive first, then the missing ones are made four at a time so a NAS isn't asked for the whole folder at once. A file that can't be read arrives without an image and doesn't stop the rest.

## Window layout

The Mac app has one window. Panels sit beside the photo and never cover it; see [decision 0004](decisions/0004-window-layout.md).

- The sidebar is a `NavigationSplitView` sidebar listing the saved folders. Each one expands into its subfolders exactly as they are on disk; Proof doesn't group or reorganize them. Each row shows how many RAW photos sit directly in that folder. A folder is read with `FolderContents.read` off the main thread when its row first appears, so a tree on a NAS costs one directory listing per visible folder.
- All Photos sits above the saved folders. It shows every RAW photo in each available saved folder and all its subfolders, ordered by folder as the expanded sidebar lists them; see [decision 0006](decisions/0006-all-photos.md). While it is selected, `Library` reads the folder tree one folder at a time with `FolderContents.read`, skipping folders already read, and the grid fills in folder by folder. Offline and missing locations are left out and named in the subtitle. The title is "All Photos". A thumbnail's help tag names the folder it is in.
- A saved folder that is `missing` is dimmed and has a Locate… button that relinks it through `FileAccess`. One that is `offline` is dimmed without the button. Removing a folder asks first and says that photos and edits are not deleted.
- The window is in one of two modes, Browse or Edit, held in `BrowseState` together with the selected photo. Photos are identified by a `PhotoReference`, their folder and file name, so photos with the same name in different folders are told apart; `ListedPhoto` pairs a photo with its folder for the grid and the filmstrip. Both modes follow the system's light or dark appearance. Browse shows the sidebar, a thumbnail grid of the selected folder and the All, 5 Stars and Edited filter (`PhotoFilter`). The title is the folder name and the subtitle its photo count. A photo counts as edited when its `.proof` sidecar exists. 5 Stars shows photos rated five stars in XMP that aren't rejected. `FolderContents.read` reads XMP sidecars while listing the folder; for photos without one, `Library` reads the XMP embedded in each photo of the selected folder, or of All Photos, in the background, so those photos join the filter as they are read. `PhotoMetadata` holds the rating, the flag (unflagged, flagged or rejected) and the label; see [decision 0005](decisions/0005-reading-xmp.md) for how each app's XMP is read.
- The grid shows each thumbnail as soon as `ThumbnailCache` delivers it, so a folder on a NAS fills in while it is read. Thumbnails are loaded for every photo in the folder, so changing the filter doesn't read it again. When more photos are listed, such as when All Photos reads another folder, thumbnails already shown are kept. Click selects a photo and the arrow keys move the selection; double-click or Return enters Edit. A photo the filter hides is deselected.
- Edit hides the sidebar, restoring it on return. The title is the photo name and the subtitle the folder and the photo's position among the photos that pass the filter ("3 of 120"). The toolbar has a back button and an inspector button; the back button and Esc return to Browse with the same photo selected. The exposure slider sits in an `.inspector` panel beside the photo.
- A filmstrip runs under the photo in Edit, one row of thumbnails of the photos that pass the filter, from the same `ThumbnailCache`. The current photo has a ring and is scrolled to the middle. Click or the left and right arrow keys switch photos without leaving Edit; the arrows stop at the first and last photo.
- The canvas in Edit is white in the light appearance and 13% gray in the dark, so the whole window changes with the system. It runs under the toolbar glass and stops at the inspector, which has the same plain color instead of its usual material, so the photo and its panel read as one surface. The sidebar and the Browse area use the same color, so the whole window is one surface in either mode. The toolbar uses the system's default background and scroll edge effect: content that scrolls under it, such as the grid's thumbnails, is blurred behind the toolbar material, so the title and subtitle stay readable. Proof doesn't hide or restyle the toolbar background. The photo is centered with a margin and stays inside the safe area.
- Proof's own interface uses only black, white and gray, so no color competes with the photo. The app's accent color is black in the light appearance and 40% gray in the dark; it colors the focused sidebar selection, the filter and the slider. White would make the selected row's text unreadable, because macOS keeps that text white. A selected thumbnail in the grid or the filmstrip has a ring a few points outside the photo, black in light and white in dark, and no fill. Folder symbols in the sidebar are gray. macOS uses an app's accent color only when the system accent is Multicolor; with another system accent, that color shows instead.
- Thumbnails in the grid and the filmstrip show what other apps recorded in XMP: a flag in the photo's top-right corner if it is flagged, and the rating as a star and a number in its bottom-left, in white on a dark backing. Unflagged and unrated photos show nothing. A rejected photo has no flag badge and is dimmed to 35% opacity, as in Lightroom. VoiceOver reads the rating and flag after the photo's name. The grid shows each photo's file name centered under it; photos sit on the bottom of their square so the name is directly under every photo.
- In Edit, the toolbar has two groups of buttons: five stars, and Flagged, Unflagged and Rejected. Clicking a star sets the rating and clicking the current one clears it; the current flag is shown selected. The flag icons follow Lightroom: a filled flag, an outlined flag, and a filled flag with an X cut out of it (SF Symbols has no such symbol). The Photo menu has the same choices with Lightroom's keys: 0 to 5 for stars, P, U and X for the flag, in Browse and Edit.
- Changed ratings and flags are kept only in memory. Proof doesn't write XMP yet, so a change lasts until the folder is read again or Proof quits, and other apps don't see it. A photo whose rating or flag changed stays visible until the filter or folder changes, even if the filter no longer matches it. XMP read in the background never replaces a rating already changed.
- Every toolbar action is also in the menu bar: Add Folder in File; the filter (All, 5-Star Photos and Edited Photos, ⌘1–⌘3), Show Sidebar and Show Inspector (⌃⌘I) in View; Edit (Return), Back to Folder (Esc), Rating (0–5) and Flag (P, U, X) in Photo.
- The sidebar selection, All Photos or a folder's `FileReference`, is remembered between launches. A selection saved before All Photos existed is still read. The selected photo is not remembered.

## Folder access

`FileAccess` in `ProofKit` is the only code that creates or resolves bookmarks. It hides how a folder was granted: on the Mac it stores a read-only security-scoped bookmark; on iOS, a `BookmarkSystem` for folders picked in the Files app can take its place. Saved locations are kept as JSON in Application Support.

- Access to a folder covers every file and subfolder inside it. Adding a folder that is already saved, or sits inside a saved folder, returns the existing location. When saved folders are nested, a file belongs to the innermost one.
- Other code refers to a file as a `FileReference`: a location's identifier plus a path relative to it. A location keeps its identifier when it moves or is relinked, so references stay valid.
- When a location is resolved, a folder moved or renamed on the same volume is followed and a stale bookmark is replaced.
- A location that can't be resolved is kept. It is `offline` when its volume, such as a NAS share, isn't mounted; bookmarks are resolved without mounting so launch doesn't wait on the network. Otherwise it is `missing` and can be relinked to another folder.
- Removing a location forgets its grant. Photos, sidecars and edits on disk are not touched. Network shares are treated as slow: thumbnails come from the RAW file's embedded preview and are cached locally, and folders on network volumes are rescanned on demand instead of watched.
