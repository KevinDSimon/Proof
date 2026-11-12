# 0028. Effects: grain, halation and bloom beside the vignette

Date: 2026-11-12
Status: Accepted

## Context
Issue #92 adds film effects: grain, halation and bloom. Grain is Lightroom's (Amount, Size, Roughness). Lightroom has no halation or bloom. Redlamp (github.com/pdcgomes/redlamp, MPL-2.0) has all three, and its code was read for the method; none of it was copied. The owner wants all three in one card with the existing vignette, as in Lightroom's Effects panel, and in one pull request.

Core Image doesn't cover them. It has no grain filter, only `CIRandomGenerator`, whose noise is tied to pixels: it would be finer on an export than on the canvas. `CIBloom` and `CIGloom` blur the whole image rather than only the highlights, so they haze the shadows, can't tell a lamp from a bright wall, and spread the same in every color, which halation doesn't.

## Decision
- One Effects card replaces the Vignette card: Vignette, Grain, Halation and Bloom, each under a heading, with one switch and one Reset. The recipe keeps `vignette` as it was and adds `grain`, `halation` and `bloom` beside it, so saved vignettes don't change.
- **Halation and bloom** are one stage, after perspective and before the tone stage, in linear light. Light spreads before the film or sensor records it, so Highlights, the curve and the rest then shape the glow too. It works on the whole photo before the crop, so a light just outside the crop still glows into it.
  - The light that spreads is the highlights of a 2048-pixel copy of the photo, fading in from a quarter of the clip point. They are found before the copy is shrunk to the map, so a small light keeps its brightness. The copy has a fixed size, so a zoomed render doesn't read the whole photo at full resolution. A sensor stops recording at its clip point while film keeps going, so a pixel near the clip point counts up to 16 times (4 stops) brighter. The exception is a pixel whose surroundings, on a 32-pixel map, are bright too: a clipped sky or window lost far less to clipping than a lamp did, and boosting it would wash the photo out.
  - The highlights are shrunk to a 1024-pixel map, which Core Image caches, and blurred there by a share of the photo's long edge. The canvas, thumbnails and export therefore look alike. Changing an Amount or Size only blurs the cached map again: on the 60 MP sample at 100% zoom that takes 4–8 ms, and an Exposure change with the glow on takes about 36 ms. Each glow averages a narrow and a wide blur, since scattered light falls off quickly near a light and then lingers.
  - Only light that spills past a pixel's own highlights is added, so an evenly bright area keeps its color.
  - Halation adds that light mostly to red, from its own red and its brightness. It adds a fifth as much, over a quarter of the distance, to green, and nothing to blue: on film the light reflects off the base back through the red layer first.
  - Bloom adds the light in its own color, and blends in a little of the whole photo, blurred, as a diffusion filter does.
- **Grain** is the last stage, after the vignette, on the cropped frame.
  - It is value noise in two octaves: grains of the chosen size, and grains half as large mixed in by Roughness. It is added to gamma-encoded values, where it looks even, and is strongest in the low midtones, where a negative is thinnest.
  - The grain is placed and sized in units of the cropped frame. Its long edge is 6000 units, so at Size 25 a grain is about two pixels on a 24-megapixel photo.
  - Where a render is smaller than that, each pixel shows the average of the grains it covers: one random value per pixel, scaled down by how many grains it holds. The canvas therefore shows the grain an export shrunk to the same size would have; a test checks that the two match within 35%. Grain is judged at 100%, as in Lightroom.
  - The hash is the PCG hash from Jarzynski and Olano, "Hash Functions for GPU Rendering" (2020).
- With an effect's Amount at 0 its stage is skipped, so saved edits render as before and `processVersion` stays 1.

## Consequences
- Redlamp's color grain, which gives each color channel its own grain, is left out for now. It can be added later as a new field without changing how these values render.
- Halation shows only where a photo has bright highlights against darker areas: street lights, the sun, a window at night. On a photo without them it changes little, as on film. The sample photo has none, so its reference render raises Exposure until the sky clips.
- A light smaller than about one pixel of the 2048-pixel copy is averaged with its surroundings before it is measured, so it may not get the clip-point boost. At that size it barely glows on film either.
- Horizon detection renders without any effect, since grain and glow aren't part of the scene.
- The strengths, radii and grain sizes were tuned by eye on the sample photo and on synthetic lights. Changing them after a release renders these values needs a new `processVersion`.
