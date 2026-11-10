# 0016. Sharpening and noise reduction from CIRAWFilter

Date: 2026-11-10
Status: Accepted

## Context
Issue #104 adds a Detail card with sharpening and noise reduction, as in Lightroom's Detail panel. `CIRAWFilter` already sharpens and reduces noise during the decode, with defaults it chooses for each photo. On the sample photo (Leica M11, ISO 64, decoder version 8) it reports support for `sharpnessAmount` (default 1), `detailAmount` (0), `luminanceNoiseReductionAmount` (0), `colorNoiseReductionAmount` (0.5), `contrastAmount` and `moireReductionAmount`. It has no sharpening radius or masking. Measured on 256-pixel crops:
- Sharpness changes the photo only when the decode scale is above 0.5. Fit-to-window renders of a large photo are not sharpened.
- Luminance noise reduction and Detail follow the photo's ISO. They do almost nothing at ISO 64; on a copy of the sample marked ISO 6400 they work strongly, and that copy's default luminance amount is 0.72. Amounts above 1 make artifacts.
- Color noise reduction works at every scale.
- `contrastAmount` is local contrast, which belongs with Texture and Clarity (#101), not here.

## Decision
- The card has Sharpening, Noise Reduction, Detail and Color Noise Reduction, each 0 to 100. Sharpening maps to `sharpnessAmount` 0 to 2, the others to 0 to 1.
- The recipe stores `null` for the camera's default, as white balance does for As Shot. The sliders show the camera's value until moved. Edits saved before the card have no `detail` and keep rendering exactly as before, so `processVersion` stays 1.
- The renderer reads the defaults when it opens a photo and sets all four amounts on every render, because it reuses one filter.
- No radius or masking: `CIRAWFilter` has none, and a separate unsharp-mask stage would sharpen on top of the decoder's own.

## Consequences
- Sharpening has to be judged at 100% zoom or when the photo is shown above half size; the slider's help says so.
- A detail change repeats the RAW decode. On the 60 MP sample it renders in about 20–50 ms (median) at a 3456×2234 fit and on a 2560×1600 region at 100%.
- Luminance noise reduction is checked only on an ISO-patched copy of the sample. A real high-ISO sample would make its reference render meaningful.
- Changing the mapping later changes saved edits, so it needs a `processVersion` bump.
