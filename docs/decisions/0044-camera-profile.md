# 0044. Camera profile

Date: 2026-11-17
Status: Accepted

## Context
Issue #198. Core Image decodes each RAW file with `CIRAWFilter`, and Proof never set its `decoderVersion`. For a Leica M11 DNG the default decoder, `8`, uses Apple's own profile for the camera and ignores the profile Leica wrote into the file. The `.dng` decoder versions apply the file's color matrices, calibration and baseline exposure, but ignore forward matrices, hue/sat maps and look tables (`scripts/dng-profile-diagnostic/RESULTS.md`). The M11's profile is two color matrices and a look table that changes nothing, so a `.dng` decoder applies it in full. Under Leica's profile the M11 sample is cooler, with bluer, more saturated blues; under Apple's it is warmer and more lavender. iPhone ProRAW is offered only `.dng` decoders and already decodes with its embedded profile. Sony, Canon, Nikon and Fujifilm raw files carry no profile Core Image can use.

## Decision
- The recipe stores `profile`, `embedded` or `apple`. `CameraProfiles` decides what a photo offers. The embedded profile is offered beside Apple's only when the default decoder isn't a `.dng` version, the file is a DNG with color matrices, and its profile has no forward matrix, no hue/sat map and no look table that changes colors. It decodes with the newest `.dng` entry in `supportedDecoderVersions`. A photo without the choice keeps its one profile whatever the recipe says.
- New edits start with `embedded`, so a Leica M11 photo opens with Leica's profile. `processVersion` is now 2. Edits saved at version 1 have no `profile` and read as `apple`, so they render as they did. Photos without a sidecar have no saved edit and open at version 2: unedited M11 photos now open with Leica's profile. Their thumbnails in the grid are the camera's own preview until they are edited, as before.
- The Histogram card at the top of the Adjust inspector has a Profile row under the capture settings (#202), not a card of its own, since a card for one row adds weight and the Histogram card has no switch to suggest the profile can be switched off. Photo › Profile in the menu bar offers the same choice. The row is a pop-up of "LEICA M11 (embedded)" and "Apple" when the photo offers both, otherwise the one profile's name, "iPhone 16 Pro (embedded)" or "Apple · ILCE-7M4". The camera model is written as the file has it. A label never names a camera maker for Apple's profile.
- Apple's profile counts as a change: an edit with it isn't neutral, so choosing it on an unedited photo is saved, and Revert to Original returns to the embedded profile. Show Original keeps the profile, since it sets the colors every adjustment starts from.
- Profile is a Copy Settings item, ticked by default, because white balance values mean different colors under each profile.

## Consequences
- The `.dng` decoder uses the DNG's DefaultCropSize, so the M11's frame grows from 9504×6320 to 9528×6328 under Leica's profile. Crops are stored as fractions of the frame, so they keep their place. The placeholder shown before the first render reads DefaultCropSize from the header for the embedded profile.
- The `.dng` decoders report `nativeSize` already scaled by the last `scaleFactor`, so the renderer reads each profile's size, as-shot white balance, sharpening, noise reduction and lens defaults once when the photo opens and keeps them. Under Leica's profile the decoder's defaults differ: sharpening 0.5 instead of 1, color noise reduction 0 instead of 0.5. The Detail sliders show the current profile's.
- On the M11 sample the as-shot white balance reads 6112 K, tint +10, under both profiles; the same Kelvin gives a different white under each. Proof doesn't convert white balance when the profile changes.
- "Embedded" depends on the newest `.dng` decoder the system has. A later macOS with a newer one could render the embedded profile differently, as a new default decoder could change Apple's.
- Profiles with forward matrices, hue/sat maps or look tables, such as those of many other DNG cameras, stay on Apple's profile until Core Image applies them or Proof applies them itself.
- Apple isn't offered as a preference for Leica files; each photo is set in its own edit.
