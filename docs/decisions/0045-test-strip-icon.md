# 0045. Test strip app icon

Date: 2026-11-20
Status: Accepted

## Context
Issue #210: the aperture P icon (decision 0042) is replaced by a darkroom test strip, the strip of paper a printer exposes in steps to choose an exposure time. It suits an editor whose main job is choosing tone.

## Decision
- The icon stays an Icon Composer file, `App/Proof/AppIcon.icon`, flat as in decision 0042: glass, specular highlights, the layer shadow and translucency are off.
- The fill is #171717. The one layer, `test-strip.svg`, is a square print: a white sheet with five gray steps from dark to light, left to right: #494949, #707070, #9A9A9A, #C5C5C5 and #EEEEEE. Everything has square corners, like cut paper, and there is no image on the steps.
- The layer is drawn at full size on the 1024-point canvas, with scale 1. The print is 620 points square, 61% of the icon's width, centered. Its white border is 36 points wide, like a print's margin, and the steps fill the 548-point square inside it at equal widths and heights.
- The border gives every step the same light edge. Without it, a strip of steps on the dark fill looked uneven: light areas on a dark ground look larger than dark ones of the same size, so the darkest step looked shorter than the lightest, and drawing the darker steps slightly taller didn't fully correct it.
- The layer is plain rectangles. A draft with an illustration on the strip, drawn with clip paths, `<use>` elements and a group transform, rendered smaller in Icon Composer than in a browser, because Icon Composer ignored the transform.

## Consequences
- The icon is edited in Icon Composer, or by replacing `test-strip.svg`. A replacement layer should use plain shapes without transforms, clip paths or `<use>`.
- The icon is black, white and gray, like the interface, and doesn't use the highlight color.
