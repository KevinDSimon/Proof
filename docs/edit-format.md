# Edit file format

Proof saves each photo's edit as JSON in a sidecar next to the original, named after the full original file name plus `.proof`:

```
L1000957.DNG
L1000957.DNG.proof
```

The sidecar travels with the photo when the folder is copied or synced, so a NAS folder carries its edits to every device.

## Example

```json
{
  "formatVersion": 1,
  "processVersion": 1,
  "basic": {
    "temperature": 0, "tint": 0, "exposure": 0.3,
    "contrast": 10, "highlights": -40, "shadows": 25,
    "whites": 0, "blacks": -5, "vibrance": 15, "saturation": 0
  },
  "curve": { "rgb": [[0, 0], [1, 1]], "red": [[0, 0], [1, 1]], "green": [[0, 0], [1, 1]], "blue": [[0, 0], [1, 1]] },
  "look": { "lut": "Portra.cube", "strength": 0.7 },
  "crop": null,
  "layers": []
}
```

## Fields

| Field | Meaning |
| --- | --- |
| `formatVersion` | Version of this JSON layout. Bumped when fields are renamed or restructured; older files are migrated on read. |
| `processVersion` | Version of the render pipeline the edit was made with. A newer Proof renders an old edit with the pipeline it was made with, so saved edits never change appearance. |
| `basic` | Lightroom-style Basic panel values. Exposure is in stops (−5 to +5); the rest run from −100 to +100. |
| `curve` | Control points per channel, each `[input, output]` from 0 to 1, sorted by input. |
| `look` | The LUT's file name in the LUT library and its strength from 0 to 1. `null` for none. |
| `crop` | Normalized rectangle and rotation angle. `null` for none. |
| `layers` | Masks with their own adjustments, applied in order. Empty until v1.2; present from the first version so masks don't need a format change. |

Missing fields take their default (no adjustment). Unknown fields are currently ignored; preserving them on save, so a file from a newer Proof survives a round trip through an older one, is a planned change.
