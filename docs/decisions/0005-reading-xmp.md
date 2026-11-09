# 0005. How ratings, flags and labels are read from XMP

Date: 2026-11-08
Status: Accepted

## Context
Decision 0002 says Proof reads star ratings and color labels from XMP but doesn't write them. Photos may have been rated in Photomator, Lightroom, Bridge, Capture One, darktable or digiKam, and these apps store the same information in different ways:

- Sidecar names: Photomator, Lightroom, Bridge and Capture One write `IMG_0001.xmp`. darktable and digiKam write `IMG_0001.DNG.xmp`. Some apps write `.XMP` in capitals. Lightroom writes into a DNG instead of beside it.
- Stars are `xmp:Rating` everywhere. Some apps write it as an attribute, others (Photomator) as an element, and a few write decimals such as `3.0`.
- Rejected: Bridge and darktable write `xmp:Rating` -1. Lightroom Classic 13.2 and later, and Photomator, write `xmpDM:pick` (1 flagged, 0 unflagged, -1 rejected) and `xmpDM:good`.
- Labels are `xmp:Label`, as text. Lightroom lets people rename and translate the labels. Capture One adds Orange and Pink, and also writes `photoshop:Urgency`, but different apps and versions use different Urgency numbers for the same color.
- Cameras write their own XMP into the DNG. On a Leica M11 it holds `xmp:Rating` 0, even for photos rated later in Photomator.

## Decision
- Look for `<name>.xmp` and `<name>.<extension>.xmp`, ignoring case. If both exist, use the one modified most recently.
- A sidecar takes the place of the XMP embedded in the photo. Embedded XMP is read only for photos without a sidecar, and only for the selected folder, in the background after the folder is listed.
- Read tags by namespace URI, not prefix, using ImageIO's XMP parser, so attribute and element forms both work.
- A photo is rejected if `xmp:Rating` is -1 or `xmpDM:pick` is -1. It is flagged if `xmpDM:pick` is 1. `xmpDM:good` is used only when `xmpDM:pick` is missing. Ratings outside 0 to 5 count as no stars.
- Keep the label text as written. Recognize red, orange, yellow, green, blue, pink and purple by English name in any capitalization. Ignore `photoshop:Urgency`.
- The 5 Stars filter leaves out rejected photos.

## Consequences
- Ratings from any of these apps show up without settings or an import step.
- A Lightroom label renamed or written in another language is kept but shown without a color.
- Reading embedded XMP opens each photo without a sidecar. On a NAS that took about 13 seconds for 119 DNGs, so 5-star photos rated inside the file appear a moment after the grid. The result isn't cached between launches yet.
- Writing ratings later must write `xmp:Rating`, `xmp:Label` and `xmpDM:pick` so these apps keep reading them.
