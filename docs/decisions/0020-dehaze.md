# 0020. Dehaze through the dark-channel prior

Date: 2026-11-10
Status: Accepted

## Context
Issue #26 adds a Dehaze slider from −100 to +100, as in Lightroom: positive values take haze out of a photo, negative values add it. Core Image has no dehaze filter. Haze can be described as `I = J·t + A·(1 − t)`: what the camera records (`I`) is the clear scene (`J`), dimmed by the share of its light that gets through (`t`), plus the haze's color (`A`) filling in the rest. Removing haze means estimating `A` and `t` for each area and solving for `J`. The dark-channel prior (He, Sun and Tang, 2009) gives that estimate: in clear areas, nearly every small patch holds something dark in at least one of red, green and blue, so a patch whose darkest channel is lifted is lifted by haze. The sample photo (`L1000725.DNG`, a dusk landscape) was rendered at +50, +100, −50 and −100 by the comparison test in `DehazeTests`.

## Decision
- Dehaze is one stage of custom Metal color kernels, compiled at run time like Highlights and Shadows (decision 0009). It runs in linear light, where the haze model holds, after Texture and Clarity and before the tone lookup.
- The haze is measured on a map 320 pixels on its long edge, as Clarity's area is, so the canvas, thumbnails and export look alike. Each map pixel's darkest channel is taken, then the darkest within 3 map pixels (about 1% of the photo).
- The haze's color is the average color of the map pixels whose dark channel is within 15% of the highest, found with `CIAreaMaximum` and `CIAreaAverage` on the map.
- The haze map is the dark channel of the photo divided by the haze's color, smoothed and enlarged with `CIEdgePreserveUpsampleFilter`, guided by the photo's brightness, so the change follows the photo's edges instead of drawing halos along them.
- At +100, the share of light let through is `1 − 0.7 × haze`, so the haziest areas, such as sky, keep at least 30% and don't turn black or noisy. There is no hard limit, which would draw a visible line in a smooth sky. At −100, each pixel moves toward the haze's color by up to half, more where there is haze already: `0.5 × (0.2 + 0.8 × haze)`.
- At 0 the stage is skipped, so saved edits render as before and `processVersion` stays 1.

## Consequences
- Removing haze also darkens the photo and makes colors stronger, as Lightroom's does, because the haze it takes out was adding light.
- With the decode cached and other tone sliders in use, a dehaze change renders at a full-screen size (3360×2234) in about 15–24 ms (median) on the owner's Mac, inside one 30 fps frame.
- The strengths, map size and haze threshold were tuned on one photo with little haze. Changing them after a release renders these values needs a new `processVersion`.
- A photo with no haze and a bright, colorful area, such as a sunset, can take that area's color as the haze's. Dehaze then shifts colors more than it clears haze.
