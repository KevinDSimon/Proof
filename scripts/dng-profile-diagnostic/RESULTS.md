# Does Proof use the Leica M11's embedded DNG profile?

Run on 2026-11-16, macOS 27.2 (26B123), one file: `L1000725.DNG` (Leica M11, firmware 2.0.2, unedited: XMP create and modify dates match the capture time). Full numbers are in `results-L1000725.txt`.

## How the app decodes today

At the time of this diagnostic, before #198, `RAWRenderer` (`Sources/ProofKit/RAWRenderer.swift`) opened each file with `CIRAWFilter(imageURL:)` and never set `decoderVersion`, so Core Image uses its default, `8`. It set only white balance (Kelvin and tint), exposure, sharpening and noise reduction, and the lens profile. Its working space is extended linear sRGB in half float. All tone and color edits ran after `filter.outputImage`, on decoded RGB.

## What the file contains

| Tag | Value | Kind |
|---|---|---|
| ProfileName | PROFILE M11 | profile |
| CalibrationIlluminant1 / 2 | Standard Light A / D65 | profile |
| ColorMatrix1 / ColorMatrix2 | two 3×3 matrices | profile |
| CameraCalibration1 / 2 | identity | profile (does nothing) |
| ProfileLookTableDims / Data | 3×2×1, every entry hue 0, saturation 1, value 1 | profile (does nothing) |
| BaselineExposure | 0 | rendering default |
| AsShotNeutral | 0.2527 1 0.6755 | per-shot white balance |

Not present: ForwardMatrix1/2, ProfileHueSatMap, ProfileToneCurve, AnalogBalance, opcode lists. So Leica's embedded profile for this camera is two color matrices and nothing else that changes the image.

## What changed the render

Each copy changes one tag (two for the forward and hue/sat entries, which need a pair). Every copy kept the original RAW payload hash and camera identity and decoded as RAW. The unmodified copy, a no-op rewrite and a repeat decode all matched the control exactly. Values are mean absolute difference in linear RGB against the control, with white balance at the file's as-shot value. "WB pinned" holds Kelvin and tint at the control's value.

| Tag changed | Default decoder (`8`, what the app uses) | `8.dng` and `9.dng` |
|---|---|---|
| ColorMatrix1 (A) | no change | changed (0.0009) |
| ColorMatrix2 (D65) | no change | changed (0.014) |
| CameraCalibration1 | as-shot render: barely (0.0002); Kelvin readout 6112 → 10683; WB pinned: changed (0.052) | changed (0.046) |
| CameraCalibration2 | no change | changed (0.045) |
| ForwardMatrix1+2 (added) | no change | no change |
| ProfileLookTableData | no change | no change |
| ProfileHueSatMap (added) | no change | no change |
| ProfileToneCurve (added) | changed (0.028) | changed (0.028) |
| AsShotNeutral | changed (white balance) | changed (white balance) |
| BaselineExposure +1 | no change | changed (0.137) |
| ProfileName | no change | no change |

The two decoder families also differ on the unmodified file: the default renders 9504×6320 with mean RGB 0.178 / 0.172 / 0.209; `9.dng` renders 9528×6328 (the DNG's DefaultCropSize) with 0.144 / 0.156 / 0.197.

## What this supports

- The default decoder, which Proof uses, ignores Leica's color matrices. It renders the M11 with Apple's own built-in profile; Core Image lists "Leica M11" as a supported camera. CameraCalibration1 only moves the Kelvin and tint mapping, not the as-shot colors.
- The `.dng` decoder versions read the color matrices, both calibrations and the baseline exposure, which is everything in this file's profile that has an effect.
- Neither family responded to forward matrices, a look table or a hue/sat map. That doesn't matter for this M11 file, whose look table is identity and which has no forward matrix or hue/sat map, but it means `.dng` decoding is not full DNG profile support for other cameras.
- This is one file, one camera and one OS build. Other M11 firmware, other Leica bodies and other macOS versions may behave differently; rerun the script to check.

## Recommendation

The supported override exists: `CIRAWFilter.decoderVersion` set to the newest `.dng` entry in `supportedDecoderVersions` (`9.dng` here). No custom decoder is needed for the M11. It changes how existing edits render (colors, exposure and a slightly larger frame), so it would need an opt-in per photo, a new `processVersion`, an `edit-format.md` update, a migration test and a reference render. Name it for what it is, such as "Embedded DNG matrices", since look tables and hue/sat maps are not applied. A post-decode LUT that imitates Leica's look stays a separate, optional approximation and must not use this name.

## Rerun

```
scripts/dng-profile-diagnostic/run.sh <original.dng> [work-dir] [scaleFactor]
DECODER_VERSION=9.dng scripts/dng-profile-diagnostic/run.sh <original.dng> [work-dir] [scaleFactor]
```

## iPhone ProRAW (`IMG_5618.DNG`, iPhone 16 Pro front camera, iOS 18.6.2)

The file is already demosaiced ("Linear Raw", 10-bit, tiled) and carries "Apple Embedded Color Profile": ColorMatrix1/2, AnalogBalance, AsShotNeutral 1 1 1, BaselineExposure +4.06, a 257-point ProfileToneCurve and a ProfileGainTableMap (DNG 1.6 local tone mapping), plus portrait, skin and sky masks. No forward matrices, look table or hue/sat map.

Core Image offers only `.dng` decoder versions for this file and uses `8.dng` by default, so the app already decodes it from the embedded profile. Every profile tag tested changed the render: ColorMatrix2, AnalogBalance, AsShotNeutral, BaselineExposure, ProfileToneCurve (made linear) and ProfileGainTableMap (removed). ProfileName and a no-op rewrite did not. Run with `scripts/dng-profile-diagnostic/proraw.sh <file.dng> <work-dir>`.
