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
    "contrast": 10, "highlights": -40, "shadows": 25,
    "whites": 0, "blacks": -5, "vibrance": 15, "saturation": 0
  },
  "curve": { "rgb": [[0, 0], [1, 1]], "red": [[0, 0], [1, 1]], "green": [[0, 0], [1, 1]], "blue": [[0, 0], [1, 1]] },
  "look": { "lut": "Portra.cube", "strength": 0.7 },
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
| `basic` | Lightroom-style Basic panel values. White balance is described below. Exposure is in stops (−5 to +5); the rest run from −100 to +100. Highlights and shadows brighten (positive) or darken (negative) the bright and dark areas of the photo; values outside −100 to +100 render as the nearest end. Contrast steepens (positive) or flattens (negative) the tones around middle gray; whites and blacks raise or lower the tones toward white and toward black, with black and white themselves left in place. These three are clamped the same way. Vibrance raises (positive) or lowers (negative) the strength of muted colors more than vivid ones and leaves grays alone; saturation changes all colors alike, and −100 makes the photo black and white. Both are clamped the same way. |
| `curve` | Control points per channel (`rgb`, `red`, `green`, `blue`), each `[input, output]` from 0 to 1 in sRGB-encoded values, sorted by input, at most 16 per channel. The RGB curve applies after Contrast, Whites and Blacks, then each color channel's curve. The curve passes through every point with monotone cubic interpolation and is flat beyond the first and last points. Values outside 0 to 1 are clamped, and a point at the same input as an earlier one is ignored. |
| `look` | The LUT's file name in the LUT library and its strength from 0 to 1. `null` for none. |
| `crop` | Turn, flips, straighten and crop rectangle, described below. `null` for none. |
| `layers` | Masks with their own adjustments, applied in order. Empty until v1.2; present from the first version so masks don't need a format change. |

Missing fields take their default (no adjustment). `look` and `crop` are written as `null` when there is none. Proof writes the file with its keys sorted and indented.

## White balance

| Field | Meaning |
| --- | --- |
| `whiteBalance` | The white balance menu's choice: `asShot`, `daylight`, `cloudy`, `shade`, `tungsten`, `fluorescent`, `flash` or `custom`. It labels the values; only `temperature` and `tint` change the render. A choice this version doesn't know reads as `custom`. |
| `temperature` | The color temperature of the light in Kelvin, 2000 to 50000. `null` keeps the camera's. |
| `tint` | From −150 (green) to +150 (magenta). `null` keeps the camera's. |

As Shot is `whiteBalance: "asShot"` with `temperature` and `tint` both `null`, and is written that way so a save replaces earlier values. A preset writes its Kelvin with a tint of 0: Daylight 5500, Cloudy 6500, Shade 7500, Tungsten 2850, Fluorescent 3800, Flash 5500. Moving either slider sets `custom`. The values are absolute, the same in every version, so a preset's Kelvin can change later without changing saved edits.

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
