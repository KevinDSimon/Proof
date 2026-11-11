# Edit file format

Proof saves each photo's edit as JSON in a sidecar next to the original, named after the full original file name plus `.proof`:

```
L1000957.DNG
L1000957.DNG.proof
```

The sidecar travels with the photo when the folder is copied or synced, so a NAS folder carries its edits to every device. When the file is created, deleted, relinked after a rename and reloaded is set out in decision 0007 (`docs/decisions/0007-edit-sidecar-lifecycle.md`).

## Example

```json
{
  "formatVersion": 3,
  "processVersion": 1,
  "basic": {
    "whiteBalance": "custom", "temperature": 4800, "tint": 12, "exposure": 0.3,
    "contrast": 10, "texture": 20, "clarity": 15, "dehaze": 10, "highlights": -40, "shadows": 25,
    "whites": 0, "blacks": -5, "vibrance": 15, "saturation": 0
  },
  "curve": {
    "rgb": [[0, 0], [1, 1]], "red": [[0, 0], [1, 1]], "green": [[0, 0], [1, 1]], "blue": [[0, 0], [1, 1]],
    "levels": { "rgb": [0, 0.5, 1], "red": [0, 0.5, 1], "green": [0, 0.5, 1], "blue": [0, 0.5, 1] }
  },
  "detail": { "sharpening": 70, "noiseReduction": null, "noiseReductionDetail": null, "colorNoiseReduction": 40 },
  "look": { "lut": "Portra.cube", "strength": 0.7 },
  "vignette": { "amount": -30, "midpoint": 50, "roundness": 0, "feather": 50 },
  "lens": { "profile": null, "chromaticAberration": { "red": 1.00012, "blue": 0.99994 } },
  "crop": {
    "x": 0.08, "y": 0.1, "width": 0.8, "height": 0.75, "angle": -2.5,
    "rotation": 90, "flipHorizontal": false, "flipVertical": false, "aspect": [4, 5]
  },
  "layers": []
}
```

## Fields

| Field | Meaning |
| --- | --- |
| `formatVersion` | Version of this JSON layout. Bumped when fields are renamed or restructured; older files are migrated on read. |
| `processVersion` | Version of the render pipeline the edit was made with. A newer Proof renders an old edit with the pipeline it was made with, so saved edits never change appearance. |
| `basic` | Lightroom-style Basic panel values. White balance is described below. Exposure is in stops (−5 to +5); the rest run from −100 to +100. Highlights and shadows brighten (positive) or darken (negative) the bright and dark areas of the photo; values outside −100 to +100 render as the nearest end. Contrast steepens (positive) or flattens (negative) the tones around middle gray; whites and blacks raise or lower the tones toward white and toward black, with black and white themselves left in place. These three are clamped the same way. Texture and clarity raise (positive) or lower (negative) local contrast: texture in fine detail a few pixels across, clarity over larger areas, mostly in the midtones. Both are measured against a share of the photo's size, so they look the same at any render size, and are clamped the same way. Files saved before they existed read both as 0. Dehaze removes (positive) or adds (negative) haze, measured against the photo's own haziest area; it is clamped the same way, and files saved before it existed read it as 0. Vibrance raises (positive) or lowers (negative) the strength of muted colors more than vivid ones and leaves grays alone; saturation changes all colors alike, and −100 makes the photo black and white. Both are clamped the same way. |
| `curve` | Control points per channel (`rgb`, `red`, `green`, `blue`), each `[input, output]` from 0 to 1 in sRGB-encoded values, sorted by input, at most 16 per channel. The RGB curve applies after Contrast, Whites and Blacks, then each color channel's curve. The curve passes through every point with monotone cubic interpolation and is flat beyond the first and last points. Values outside 0 to 1 are clamped, and a point at the same input as an earlier one is ignored. `levels` holds each channel's black, midtone and white handles as `[black, midtone, white]`, described below. |
| `detail` | Sharpening and noise reduction, described below. |
| `look` | The LUT's path in the LUT library and its strength from 0 to 1. The path is relative to the library, with folders separated by `/`, as in `Portra/400.cube`; a LUT outside any folder is its file name alone, as edits saved before folders have it. A path with an empty, hidden or `..` part is skipped. Strength outside 0 to 1 renders as the nearer end. A LUT that can't be found is skipped. `null` for none. |
| `vignette` | Darkened or lightened edges, centered on the cropped frame, described below. |
| `lens` | Lens corrections, described below. |
| `crop` | Turn, flips, straighten and crop rectangle, described below. `null` for none. |
| `layers` | Masks with their own adjustments, applied in order. Empty until v1.2; present from the first version so masks don't need a format change. |

Missing fields take their default (no adjustment). `look` and `crop` are written as `null` when there is none. Proof writes the file with its keys sorted and indented.

## Levels

Each channel's handles apply before its points, as in Photoshop's Levels followed by Curves.

| Value | Meaning |
| --- | --- |
| `black` | From 0 to 1. Tones at or below it become black. Default 0. |
| `midtone` | Where middle gray lands, as a fraction of the way from `black` to `white`, from 0.05 to 0.95. Below 0.5 brightens the middle tones, above 0.5 darkens them. Default 0.5. |
| `white` | From 0 to 1. Tones at or above it become white. Default 1. |

Between `black` and `white` the tone is stretched to 0…1 and raised to the power that maps `midtone` to 0.5. `white` is kept at least 0.02 above `black`. A missing channel, or a missing `levels`, means the defaults; files saved before levels existed read that way.

## Detail

Each value runs from 0 to 100, and `null` keeps the camera's default, which `CIRAWFilter` chooses for each photo from its camera and ISO. Values outside 0 to 100 render as the nearer end. A missing `detail`, as in files saved before it existed, means all four are `null`, so those edits render as they always did. See decision 0016.

| Field | Meaning |
| --- | --- |
| `sharpening` | Edge sharpening, `CIRAWFilter.sharpnessAmount` from 0 to 2 (value ÷ 50). Applies only when the photo is decoded above half size. |
| `noiseReduction` | Luminance noise reduction, `luminanceNoiseReductionAmount` from 0 to 1 (value ÷ 100). Its effect grows with the photo's ISO. |
| `noiseReductionDetail` | How much fine detail luminance noise reduction keeps, `detailAmount` from 0 to 1. |
| `colorNoiseReduction` | Color noise reduction, `colorNoiseReductionAmount` from 0 to 1. |

## Vignette

Lightroom's post-crop vignetting. It applies after the crop, so it centers on the cropped and straightened frame. Values outside their ranges render as the nearer end. With `amount` at 0 nothing changes, whatever the other three hold. A missing `vignette`, as in files saved before it existed, means no vignette; a missing field inside it takes the default below. See decision 0021.

| Field | Meaning |
| --- | --- |
| `amount` | −100 to +100, default 0. Negative darkens the edges like exposure, by up to 3 stops at −100. Positive lightens them by up to 3 stops, easing each channel toward white so highlights don't clip. |
| `midpoint` | 0 to 100, default 50. Where the effect is half, from close to the center (0) to near the corners (100). |
| `roundness` | −100 to +100, default 0. 0 is an oval matching the frame, +100 a circle of the same area, −100 a rounded rectangle following the frame's corners. |
| `feather` | 0 to 100, default 50. How gradually the effect fades in; 0 is a hard edge. |

## Lens corrections

Corrections for the lens, applied as the photo is decoded, before every other adjustment: first the profile, then chromatic aberration. Show Original keeps them, as it keeps the crop. A missing `lens`, as in files saved before it existed, means both are `null`, so those edits render as they always did.

| Field | Meaning |
| --- | --- |
| `profile` | `true` applies the file's distortion and vignetting correction, `false` leaves the lens uncorrected, and `null` keeps the decoder's default for the photo, which Proof writes whenever the choice matches that default. Ignored for files with no correction, such as Leica M DNGs, which render the same either way. |
| `chromaticAberration` | Remove Chromatic Aberration: `red` and `blue` are the scales, about the center of the uncropped photo, at which those channels are read to line up with green. 1 leaves a channel in place; values outside 0.99 to 1.01 render as the nearer end. Proof measures them when the switch is turned on and doesn't measure again on read (decision 0023). `null` while it is off. |

## White balance

| Field | Meaning |
| --- | --- |
| `whiteBalance` | The white balance menu's choice: `asShot`, `auto`, `daylight`, `cloudy`, `shade`, `tungsten`, `fluorescent`, `flash` or `custom`. It labels the values; only `temperature` and `tint` change the render. A choice this version doesn't know reads as `custom`. |
| `temperature` | The color temperature of the light in Kelvin, 2000 to 50000. `null` keeps the camera's. |
| `tint` | From −150 (green) to +150 (magenta). `null` keeps the camera's. |

As Shot is `whiteBalance: "asShot"` with `temperature` and `tint` both `null`, and is written that way so a save replaces earlier values. A preset writes its Kelvin with a tint of 0: Daylight 5500, Cloudy 6500, Shade 7500, Tungsten 2850, Fluorescent 3800, Flash 5500. Auto writes the temperature and tint Proof estimated from the photo (see `docs/decisions/0018-auto-adjust.md`) and sets `auto`; the estimate is not repeated when the file is read, so the photo renders the same if a later version estimates differently. Versions before Auto read `auto` as `custom` with the same values. Moving either slider sets `custom`. The values are absolute, the same in every version, so a preset's Kelvin can change later without changing saved edits.

## Crop

| Field | Meaning |
| --- | --- |
| `rotation` | Quarter turns clockwise: 0, 90, 180 or 270. Applied first, to the photo as the camera oriented it. |
| `flipHorizontal`, `flipVertical` | Mirror the turned photo left to right and top to bottom. Applied after the turn. Proof writes both flips together as a half turn instead. |
| `x`, `y`, `width`, `height` | The crop rectangle, from 0 to 1 of the turned and flipped photo's width and height, measured from its top left. |
| `angle` | Straighten in degrees, from −45 to 45. Positive turns the photo clockwise around the rectangle's center, under the rectangle; the result is the rectangle, upright. |
| `aspect` | The locked ratio as `[width, height]`, such as `[4, 5]`, or `null` for freeform. It only says which shape the crop tool keeps; the rectangle alone sets the render. |

Missing crop fields take their default: the whole photo, no straighten, no turn or flips, freeform. The rectangle is expected to lie within the photo once straightened; Proof keeps it there. A crop that changes nothing is written as `null`.

## Earlier formats

Format 2 had `crop` with the rectangle and `angle` but no turn, flips or ratio. No version of Proof wrote or rendered one, so a format 2 crop is read with its rectangle and angle as they are, no turn or flips and a freeform ratio, and saved as format 3.


Format 1 stored `temperature` and `tint` as −100 to +100 offsets. No version of Proof rendered them, so a format 1 file is read with both `null`, keeping the camera's white balance, and saved as format 2.

## Fields Proof doesn't recognize

A sidecar written by a newer Proof may have fields this version doesn't know, at the top level or inside an object such as `basic` or a layer. Proof keeps them: when it saves, it writes the fields it knows over the JSON it read, so the rest stay as they were. Fields inside `layers` are kept when the number of layers is unchanged. A sidecar with unrecognized fields is never deleted for being neutral (decision 0007).
