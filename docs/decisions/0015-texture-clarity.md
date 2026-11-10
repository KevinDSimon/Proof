# 0015. Texture and clarity through a custom kernel

Date: 2026-11-10
Status: Accepted

## Context
Issue #101 adds Texture and Clarity, which raise or lower local contrast as in Lightroom: Texture in fine detail, Clarity over larger areas, mostly in the midtones. Core Image's `CIUnsharpMask` and `CIHighlightShadowAdjust` only raise contrast, and their radius is in pixels, so the same value would look different on the canvas, on a thumbnail and in an export. The sample photo (`L1000725.DNG`, a dusk landscape) was rendered with each slider at +100 and −100 by the comparison test in `TextureClarityTests`.

## Decision
- Texture and clarity are one custom Metal color kernel, compiled at run time like Highlights and Shadows (decision 0009). The stage runs in linear light after Highlights and Shadows and before the tone lookup.
- Each pixel's brightness, in stops from middle gray, is compared with two blurred versions of it. Texture uses a Gaussian blur with a radius of 0.07% of the photo's long edge. Clarity uses a map 320 pixels on its long edge, smoothed and enlarged again with `CIEdgePreserveUpsampleFilter`, so the area follows edges and raising Clarity doesn't draw halos along them. Both sizes are a share of the photo, so every render size looks alike.
- The difference, limited to ±2 stops, is scaled by the slider and applied as a gain to red, green and blue alike, which keeps hue and saturation. At +100, Texture adds 90% of the fine detail and Clarity 60% of the area detail; at −100, Texture removes 50% and Clarity 45%. Clarity fades out in deep shadows and in highlights; Texture fades out only in deep shadows, where it would raise noise.
- With both at 0 the stage is skipped, so saved edits render as before and `processVersion` stays 1.

## Consequences
- With the decode cached and every tone slider in use, a texture or clarity change renders at a full-screen size (3360×2234) in about 14–18 ms (median) on the owner’s Mac when measured on its own, inside one 30 fps frame.
- The strengths, radii and fades were tuned on one photo. Changing them after a release renders these values needs a new `processVersion`.
- At −100, Clarity gives a soft, glowing look, and Texture a visible smoothing at screen size; both match Lightroom's direction but not its exact amount.
