# 0023. Removing chromatic aberration by measuring the photo

Date: 2026-11-11
Status: Accepted

## Context
Issue #78 adds a Lens Corrections card. Lightroom's has a Remove Chromatic Aberration checkbox beside its profile corrections. `CIRAWFilter` has no setting for it, and the lens profiles it can apply are absent from many RAW files, including every Leica M DNG. Lateral chromatic aberration is the lens focusing red and blue at a slightly different size from green: colored fringes along edges that grow from nothing at the center toward the corners. Longitudinal aberration, the purple and green fringes around out-of-focus highlights, doesn't follow the center and isn't addressed here. The sample photo (`L1000725.DNG`, Summicron-M 35 ASPH on an M11) measures red at 1.00012 and blue at 0.99994, under a pixel at the corners at full resolution.

## Decision
- Model lateral aberration as one scale per channel about the photo's center, relative to green, as lensfun's linear `tca` term does. Correcting reads red and blue at those scales, so each lines up with green.
- Measure the scales from the photo itself when the switch is turned on, rather than from a lens database. The whole uncropped photo is rendered with the edit's white balance, detail and lens profile at 3000 pixels on the long edge, in linear light. Proof takes the 40,000 strongest edges that face away from the center, are more than 30% of the way to the corners and aren't clipped, and finds the scale at which each channel's slope across those edges best matches green's: a coarse search from 0.996 to 1.004, a fine one around its best, then a parabola through the finest three. Fewer than 200 such edges measure as 1. It takes about a second in an optimized build.
- Store the measured scales in the recipe (`lens.chromaticAberration`) instead of measuring on each render, as Auto white balance stores its values (decision 0018). Renders stay fast, and a later, better measurement doesn't change saved edits.
- Correct right after the RAW decode with one Metal kernel that samples red and blue at their scales about the decoded photo's center. Scales are fractions of the distance from the center, so they apply at any render size, and the crop, applied later, doesn't move the center. Values are kept between 0.99 and 1.01.

## Consequences
- Turning the switch on for a photo without fringes stores scales near 1, which change almost nothing.
- A lens whose aberration doesn't grow evenly toward the corners, such as some wide-angle designs, is only partly corrected. A curved model would need more measured values and a new field.
- Show Original keeps the correction, like the lens profile and the crop.
- In a debug build the measurement takes several seconds, since its loops run unoptimized.
