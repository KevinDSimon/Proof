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
| Ratings and labels | XMP sidecar (`IMG_0001.xmp`) or XMP embedded in the DNG | Other apps; Proof reads only |
| Edit recipe | `IMG_0001.DNG.proof` next to the original, JSON | Proof |
| Thumbnails, folder index | Application Support | Proof; disposable |

See [edit-format.md](edit-format.md) for the recipe format.

## Window layout

The Mac app has one window. Panels sit beside the photo and never cover it; see [decision 0004](decisions/0004-window-layout.md).

- The sidebar is a `NavigationSplitView` sidebar listing the saved folders. Each one expands into its subfolders exactly as they are on disk; Proof doesn't group or reorganize them. Each row shows how many RAW photos sit directly in that folder. A folder is read with `FolderContents.read` off the main thread when its row first appears, so a tree on a NAS costs one directory listing per visible folder.
- A saved folder that is `missing` is dimmed and has a Locate… button that relinks it through `FileAccess`. One that is `offline` is dimmed without the button. Removing a folder asks first and says that photos and edits are not deleted.
- The toolbar holds the photo name and folder as the window title and subtitle, the All, 5 Stars and Edited filter (`PhotoFilter`), and the exposure slider. A photo counts as edited when its `.proof` sidecar exists. Star ratings are read from XMP in a later issue; until then the 5 Stars filter shows nothing.
- Until the filmstrip arrives, the canvas shows the selected folder's first photo that passes the filter. The selected folder is remembered between launches as a `FileReference`.

## Folder access

`FileAccess` in `ProofKit` is the only code that creates or resolves bookmarks. It hides how a folder was granted: on the Mac it stores a read-only security-scoped bookmark; on iOS, a `BookmarkSystem` for folders picked in the Files app can take its place. Saved locations are kept as JSON in Application Support.

- Access to a folder covers every file and subfolder inside it. Adding a folder that is already saved, or sits inside a saved folder, returns the existing location. When saved folders are nested, a file belongs to the innermost one.
- Other code refers to a file as a `FileReference`: a location's identifier plus a path relative to it. A location keeps its identifier when it moves or is relinked, so references stay valid.
- When a location is resolved, a folder moved or renamed on the same volume is followed and a stale bookmark is replaced.
- A location that can't be resolved is kept. It is `offline` when its volume, such as a NAS share, isn't mounted; bookmarks are resolved without mounting so launch doesn't wait on the network. Otherwise it is `missing` and can be relinked to another folder.
- Removing a location forgets its grant. Photos, sidecars and edits on disk are not touched. Network shares are treated as slow: thumbnails come from the RAW file's embedded preview and are cached locally, and folders on network volumes are rescanned on demand instead of watched.
