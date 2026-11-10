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
- The RGB curve also has black, midtone and white handles in a track under the graph, as in Photoshop's Levels. They apply before the curve's points, and the graph draws handles and points together. Lightroom's three triangles under its curve only move the boundaries of its parametric regions, so with no parametric curve they would have nothing to do; Levels-style handles give the black point, white point and middle-tone brightness in one place instead.
- A point is removed by dragging it off the graph, by double-clicking it, or by Delete. Double-clicking a handle resets it.
- A switch in the Curve header hides the curve on the canvas to compare with and without it. It changes only the view, not the edit, and turns back on when the curve is edited or another photo is opened.
- The edit format holds handles for every channel, so color channels can get them later without a format change; for now only RGB shows them. The red, green and blue graphs instead show a faint color field, as Lightroom does: the channel's color above the diagonal and its opposite below, so it's clear which way a point shifts the photo.
- The red, green and blue curves are drawn in the histogram's channel colors. Like the histogram and the slider tracks, they show the photo's colors, so they are an exception to the gray interface.
- A brightness-only mode, editing the curve by dragging on the photo, and eyedroppers are left for later issues.

## Consequences

The interpolation decides how saved curves render, so changing it needs a `processVersion` bump. The levels math is fixed the same way. A brightness-only mode can't join the per-channel lookup; it would be its own stage. Curves never rendered before this change, so no saved edit changes appearance and `processVersion` stays at 1.
