# 0009. Highlights and shadows through a custom kernel

Date: 2026-11-09
Status: Accepted

## Context
Issue #14 adds the Highlights and Shadows sliders. Core Image has `CIHighlightShadowAdjust`, which would need no code of our own. Its highlight amount runs from 0 to 1 and can only darken highlights, so the slider's right half, which brightens them, would have nothing to render. The built-in filter was rendered next to a custom kernel on the sample photo (`L1000725.DNG`, a dusk landscape) with the comparison test in `HighlightsShadowsTests`. At its strongest setting the built-in filter barely darkened the bright clouds and sky, while its shadow lift was similar to the custom kernel's. Neither showed a visible halo along the ridge of Half Dome.

## Decision
- Highlights and shadows are a custom Metal color kernel, compiled at run time from source with `CIKernel.kernels(withMetalString:)`, so the Swift package needs no Metal build step.
- The kernel works in linear light right after the RAW decode. Each pixel's brightness is judged by its area: brightness is reduced to a map 96 pixels on its long edge, smoothed, and enlarged again with `CIEdgePreserveUpsampleFilter`, guided by the photo, so the area follows edges. The map is a fixed share of the photo, so the canvas, thumbnails and export agree.
- The sliders apply a gain in stops to red, green and blue alike, which keeps hue and saturation. At ±100, Highlights darkens bright areas by up to 1.5 stops and brightens them by up to 0.75; Shadows brightens dark areas by up to 2 stops and darkens them by up to 1.
- With both at 0 the stage is skipped, so neutral edits render as before and `processVersion` stays 1. No release has rendered these values.

## Consequences
- The kernel compiles on its first use, which adds about 120 ms to that one render. After that, a highlights or shadows change renders a full-window image in about 6 ms on an M2.
- Compiling at run time needs a GPU that supports dynamic libraries, which every Apple silicon Mac, iPad and iPhone does. Where it isn't supported, the sliders have no effect rather than failing the render.
- The strengths and the area size were tuned on one photo. Comparison on a backlit scene, a high-contrast scene and a dark interior is still owed in #14, and may change the numbers before a release fixes them.
