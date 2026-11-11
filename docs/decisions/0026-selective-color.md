# 0026. Selective color with a hue graph and eight shared color ranges

Date: 2026-11-11
Status: Accepted

## Context
Issue #102 asks whether to build selective color, and how: Lightroom's Color Mixer shows Hue, Saturation and Luminance sliders for eight ranges at once (24 sliders); Photomator shows a graph of the photo's colors, a row of eight color swatches, and Hue, Saturation and Brightness sliders for the chosen range. Black & White (#100), planned next, mixes the same kind of ranges into gray, using Lightroom's names: Red, Orange, Yellow, Green, Aqua, Blue, Purple, Magenta.

## Decision
- Build it, as Photomator lays it out (owner's choice): the graph, the swatches and three sliders, on a Selective Color card after Color. The graph shows how much of each hue the photo holds, as bars in their own colors; the chosen range's bars are full and the others dimmed. Clicking the graph chooses the range under the pointer; the graph isn't dragged. The graph is spaced like the swatches, not by degrees, so each swatch sits under the hues it adjusts.
- The chosen swatch is marked with a ring, not Photomator's blue fill. As in Photomator, the swatches don't show which ranges have been changed; VoiceOver reads it. The sliders are the inspector's `AdjustmentSlider`, with tracks that follow the chosen range: Hue runs from the previous range's color through its own to the next's, which is exactly what −100 to +100 reaches; Saturation runs from gray to the color; Brightness from the color dark to light. The ranges' colors are the one exception to the gray interface, as the histogram and slider tracks are. Photomator's ML button is left out.
- Eight ranges, in `ProofKit` as `ColorRange`, so Black & White can reuse them: Lightroom's names, centered at 0°, 30°, 60°, 120°, 180°, 225°, 270° and 315°. Warm centers are closer together because the eye separates warm hues over a smaller turn of the hue circle.
- One Metal color kernel, after Vibrance and Saturation and before the look. It finds each pixel's hue and saturation in HSV of the color encoded with a 2.2 gamma, close enough to the screen's encoding to place hues where they are seen, and weighs the two ranges whose centers it lies between with a smoothstep, so there is no edge between ranges. Hue turns by up to the distance to the neighbor's center; saturation scales by 1 + value ÷ 100; brightness is a gain of up to 1.5 stops in linear light, which keeps hue and saturation, with lightening eased on the brightest channel so colors don't clip. The effect fades in over saturations from 0.02 to 0.2, so grays and the unsteady hues of near-grays are left alone.
- The recipe stores `selectiveColor` as an object keyed by range name, each with `hue`, `saturation` and `brightness`. Missing means 0, so earlier edits render as before and `processVersion` stays 1. With every range at 0 the stage is skipped.
- The histogram measured from each canvas render now also counts hues, weighted by saturation, in 120 bins from a 256-pixel copy, on the CPU. It shows the edited photo, as the main histogram does.

## Consequences
- The card's switch starts off unless the edit has a selective color change, like Curve and Vignette.
- HSV hue isn't perceptually even: a 30° turn looks larger in some places than others, and hue changes can change apparent brightness (yellow turned toward green looks darker). Lightroom works in a perceptual space. Moving to one later changes how these values render, so it needs a new `processVersion`.
- The strengths (hue to the neighbor's center, 1.5 stops, the 0.02–0.2 fade) were chosen by reasoning and checked on the sample photo, not matched to Lightroom or Photomator numerically. Changing them after a release needs a new `processVersion`.
- Black & White can take `ColorRange` and the same weighting for its mix.
