# 0021. Vignette after the crop, in Lightroom's units

Date: 2026-11-10
Status: Accepted

## Context
Issue #105 adds a Vignette card that darkens or lightens the edges of the photo as a creative effect, like Lightroom's post-crop vignetting: Amount (−100 to +100), Midpoint, Roundness and Feather. It has to center on the cropped frame and follow any crop. Lens corrections (#78, #79), which remove the lens's own corner darkening, aren't built yet; this vignette has to come after them so it looks the same whichever lens took the photo. Core Image's `CIVignette` and `CIVignetteEffect` take a radius and intensity in pixels and have no roundness or feather, so they can't map to Lightroom's sliders. The sample photo (`L1000725.DNG`) was rendered at −50, −100, +50, +100, and −100 with Roundness +100, Feather 0 and Midpoint 0 by the comparison test in `VignetteTests`.

## Decision
- Vignette is the last stage, after turn, flip, straighten and crop, so it centers on the cropped frame without knowing the crop, and lens corrections in step 1 always come before it. A zoomed region is cut from the same graph afterwards, so it matches the whole frame.
- It is one Metal color kernel, compiled at run time like Highlights and Shadows (decision 0009), in linear light. The shape is measured from the frame's center in units of an oval whose edge touches the frame's sides: Roundness above 0 draws its axes toward a circle of the same area; below 0 it raises the oval's exponent from 2 to 8, toward a rounded rectangle. Midpoint sets where the effect is half, from 0.3 to 1.3 of the oval. Feather sets the width of a smoothstep around it, up to 1.2 times the midpoint, and never less than two pixels, so Feather 0 has a clean edge.
- Darkening scales each pixel like exposure, up to 3 stops at −100, which keeps colors' hue, as Lightroom's Highlight Priority style does. Lightening raises shadows and midtones by up to 3 stops but eases each channel toward white (`g·x / (1 + (g − 1)·x)`), so highlights approach white instead of clipping.
- The recipe stores `vignette` with Lightroom's four values. With Amount at 0 the stage is skipped, so saved edits render as before and `processVersion` stays 1.
- The card has an on/off switch and starts off unless the edit has a vignette, like Curve, Detail and Looks. Midpoint, Roundness and Feather are dimmed while Amount is 0, because they change nothing then.

## Consequences
- Lightroom's Style menu (Highlight Priority, Color Priority, Paint Overlay) and its Highlights slider are left out. Darkening behaves like Highlight Priority with Highlights at 0. Either can be added later as new fields without changing how these values render.
- Horizon detection renders without the vignette, since darkened corners aren't part of the scene.
- While the crop tool is open the canvas shows the uncropped photo, so the vignette centers on it until the crop is applied.
- Rendered to 8 bits, a smooth sky falls off in single steps with no skipped levels at ±100 (tested). The working format is half-float, so banding comes only from the 8-bit display, as for any gradient.
- The strengths and shape constants were tuned on one photo by eye against Lightroom's look. Changing them after a release renders these values needs a new `processVersion`.
