# 0035. Crop and perspective correction saved by the camera

Date: 2026-11-15
Status: Accepted

## Context
Issue #86. Some cameras record a crop or a perspective correction in the RAW file instead of changing the image data. Lightroom reads these and opens the photo corrected. `CIRAWFilter` ignores them, so Proof opened the same photos uncorrected and uncropped.

Two cases were checked:

- **Leica Q digital zoom.** The Q2 and Q3 keep the whole sensor image in the DNG and record the 35, 50, 75 or 90 mm framing in the standard DNG tag `DefaultUserCrop`: top, left, bottom and right, from 0 to 1 of the DNG default crop, in the file's stored orientation. Lightroom applies it as the starting crop and lets the person widen it back to the full frame. ImageIO exposes the tag in the DNG properties. No Q file was available, so this was confirmed from the DNG specification and owners' reports, not from a sample.
- **Leica M11 perspective control.** A real M11 DNG has no Adobe `crs:` crop or perspective values. The correction is in Leica's own XMP namespace, `http://leica-camera.com/digital-shift-assistant/1.0/` (`xmpDSA`): the camera's pitch and roll in degrees, the 35 mm focal length, the four corners of the corrected frame, and two flags, `ApplyAutomatically` and `CorrectionAlreadyApplied`. In the sample, `ApplyAutomatically` is `False`.

## Decision
- `CameraSettings` in `ProofKit` reads both from the file's header and embedded XMP. Only the metadata is read; the original is never written to.
- A photo with no `.proof` sidecar opens with these as its edit: the user crop as `crop`, locked to its own shape, and the Leica correction as Transform sliders. Both are ordinary values, editable and resettable like any other, and copied and pasted as any crop or Transform is.
- The Leica correction is used only when `ApplyAutomatically` is `True` and `CorrectionAlreadyApplied` isn't. A file that records the angles without asking for them opens uncorrected, as in Lightroom. There is no separate control for applying it by hand.
- Pitch becomes Vertical and roll becomes Rotate. `PerspectiveTransform` assumes a 43 mm lens; the pitch is converted to the tilt that makes vertical lines parallel through that lens instead of the real one, which differs only in how much the photo stretches. The signs and the conversion were checked against the corners the camera records: on the M11 sample, the corrected frame traced back onto the photo matches those corners' slopes and the ratio of their top and bottom widths to within 0.0002.
- The edit a photo opens with replaces "neutral" wherever Proof decides whether a photo has an edit. A sidecar is deleted when the edit returns to it, and written when the edit differs from it, including a fully neutral edit that removes the camera's crop, so the crop doesn't come back. Revert to Original returns to it.
- Only photos without a sidecar change how they open. Saved edits render as they did, so `processVersion` is unchanged, and the edit format is unchanged.

## Consequences
- Opening an unedited photo reads its metadata once more, on the main thread with its sidecar. Export of an unedited photo reads it too.
- A thumbnail of an unedited photo with camera settings is rendered from the RAW data with them, instead of read from the embedded preview, so the grid matches Edit. The cache keeps it under the same name as any unedited thumbnail, so a cache hit still reads only the file's size and date. A neutral edit of such a photo has its own cache entry. Thumbnails cached before this change keep showing the uncropped preview until the file changes or the cache is cleared.
- Other cameras' in-file corrections, such as Adobe `crs:` crop values written by a converter, aren't read. They can be added to `CameraSettings` when a sample shows they are needed.
