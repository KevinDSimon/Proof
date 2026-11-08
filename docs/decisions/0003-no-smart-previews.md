# 0003. No smart previews for now; keep the RAW decode cached instead

Date: 2026-11-08
Status: Accepted

## Context
Phase 0 asks for an exposure slider that responds in real time on local disk and on the Synology share. Issue #4 measured a 60 MP Leica M11 DNG (`L1000725.DNG`, 57 MB) on an Apple M2 against three targets: embedded preview under 100 ms, a slider render under 50 ms, and a full render under 2 s. Lightroom-style smart previews (a smaller copy of each photo, decoded and cached locally) were the fallback if the RAW file was too slow to edit directly.

Median of repeated reads; the first read is listed separately because it is the only one that can miss the file cache.

| Measurement | Local disk | NAS (SMB) |
| --- | --- | --- |
| Embedded preview, 512 px | 41 ms | 199 ms (first 400 ms) |
| Embedded preview, 1600 px | 76 ms | 227 ms (first 271 ms) |
| Embedded preview, 2880 px | 133 ms | 279 ms (first 565 ms) |
| Slider render, `scaleFactor` 0.25 | 154 ms | 150 ms |
| Slider render, `scaleFactor` 0.125 | 148 ms | 143 ms |
| Open and full-resolution render | 1.04 s | 1.00 s (first 2.75 s) |

The M11's embedded preview is a full-size JPEG. Asking ImageIO for a smaller size decodes it faster, but over SMB every read goes back to the share and takes about 200 ms or more.

The slider misses its target by the same amount on both volumes, and a render with a quarter of the pixels is barely faster. Once a photo is open, the network plays no part. The time goes to decoding the RAW data again on every exposure change, because `RAWRenderer` creates its `CIContext` with `cacheIntermediates` turned off. With caching turned on, an exposure change at `scaleFactor` 0.25 took 3–6 ms after the first render, which took about 770 ms. Exposure +1 and −1 still brightened and darkened the image, and returning to 0 gave the same pixels as before.

## Decision
Proof does not build smart previews. Interactive edits keep rendering from the original RAW file, and the renderer keeps Core Image's intermediate results between renders so that the decode runs once per photo and size. Turning caching on is its own issue, separate from this measurement.

Embedded previews are never read straight from a network share for display: thumbnails and the first preview shown on open are cached locally, as `architecture.md` already describes.

## Consequences
- No second copy of each photo to generate, store or keep in sync, and edits always render from the original data.
- Opening a photo still costs one full decode (about 0.8 s at screen size), so the canvas shows the cached embedded preview until the first render finishes.
- The first full render of a file on the share is slower than the 2 s target (2.75 s) because the whole file has to be read over the network. That affects export, not the slider.
- Photos can't be edited while the share is offline. If that becomes a requirement, smart previews come back as a new decision record.
- Caching uses GPU memory for each open photo. The renderer should hold one photo's intermediates at a time.
