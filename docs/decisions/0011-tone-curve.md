# 0011. Tone curve

Date: 2026-11-10
Status: Accepted

## Context

Phase 3 adds a tone curve. We looked at how five editors handle one: Lightroom, Capture One, Apple Photos, Pixelmator Pro and darktable. All five have a point curve. Lightroom also has a parametric curve with four region sliders. Lightroom, Photos and Pixelmator Pro apply the RGB curve to each channel separately, which raises saturation along with contrast. Capture One adds a Luma curve that changes brightness only, and Lightroom's Refine Saturation slider can do the same. darktable lets the person choose how the curve is drawn between points, and its manual warns that a plain cubic spline overshoots when points are close together.

## Decision

- A point curve only, on RGB, Red, Green and Blue. Proof has no parametric curve: the Highlights, Shadows, Whites and Blacks sliders already cover it.
- The RGB curve applies to each channel separately, as in Lightroom, Photos and Pixelmator Pro. It joins Contrast, Whites and Blacks in the lookup from `0010-tone-lookup.md`, in this order: the sliders, then the RGB curve, then each channel's own curve.
- Curves are drawn through their points with monotone cubic interpolation (PCHIP, as in SciPy's `PchipInterpolator`). Between two points the curve never rises above or falls below them, so close points can't reverse tones. Left of the first point and right of the last the curve is flat, so moving an end point inward clips.
- Points are in sRGB-encoded values, the same scale the lookup and histogram use. A channel has at most 16 points.
- The red, green and blue curves are drawn in the histogram's channel colors. Like the histogram and the slider tracks, they show the photo's colors, so they are an exception to the gray interface.
- A brightness-only mode, editing the curve by dragging on the photo, and eyedroppers are left for later issues.

## Consequences

The interpolation decides how saved curves render, so changing it needs a `processVersion` bump. A brightness-only mode can't join the per-channel lookup; it would be its own stage. Curves never rendered before this change, so no saved edit changes appearance and `processVersion` stays at 1.
