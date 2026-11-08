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

A render request always carries a target size. Interactive renders use a reduced `scaleFactor` while a control is being dragged and full screen resolution on release. Only export renders at full sensor resolution.

## Files and data

| Data | Where it lives | Who writes it |
| --- | --- | --- |
| Original RAW | Its own folder | Never written |
| Ratings and labels | XMP sidecar (`IMG_0001.xmp`) or XMP embedded in the DNG | Other apps; Proof reads only |
| Edit recipe | `IMG_0001.DNG.proof` next to the original, JSON | Proof |
| Thumbnails, folder index | Application Support | Proof; disposable |

See [edit-format.md](edit-format.md) for the recipe format.

## Folder access

`FileAccess` hides how a folder was granted. On the Mac it resolves a security-scoped bookmark; on iOS, a folder picked in the Files app. Network shares are treated as slow: thumbnails come from the RAW file's embedded preview and are cached locally, and folders on network volumes are rescanned on demand instead of watched.
