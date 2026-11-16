# 0039. Spot removal

Date: 2026-11-16
Status: Accepted

## Context
Issue #169 adds a tool for removing small blemishes, mainly sensor dust: click a spot to cover it from a nearby area, with an adjustable size, and move or delete spots afterwards. Spots are stored in the edit recipe and have to stay on what they cover after a crop and at every render size. Core Image has no healing filter. Painted strokes, for hairs or wires, and a view that makes dust easier to find were left for later issues.

## Decision
- Each spot is a circle and a source circle of the same size. Positions are from 0 to 1 of the whole photo after lens corrections and perspective and before the crop; the radius is a fraction of the long edge. The crop's own point mapping (`Crop.photoPoint` and `resultPoint`) takes the tool's clicks to that space and back, so the turn, flips, straighten and rectangle don't move a spot.
- Spots apply in step 1, after perspective and before halation and bloom, so dust doesn't glow and a spot can take from outside the crop. They apply in order, each to the result of the ones before it.
- Clone moves the source onto the spot and blends it in with a radial mask: full inside, fading to nothing at the edge over Feather percent of the radius (at least one pixel), scaled by Opacity.
- Heal does the same, but first multiplies the moved source, per channel, by the ratio of the blurred surroundings of the spot to the blurred surroundings of the source. Only pixels outside the circle count, so the dust doesn't; blurring by the radius carries the surroundings smoothly into the circle. A ratio rather than a difference, because light in linear values scales and dust takes away a share of it. The ratio is limited to 16 so a black source can't blow up. It is one Metal color kernel compiled at run time, like the other stages.
- A new spot takes its source from beside it at once, then from the circle `SpotRemoval.bestSource` chooses: of 32 nearby candidates, two and a half to three and a half radii away and wholly on the photo, the one whose ring of surroundings has the most similar texture to the spot's (in log luminance; for Heal with the brightness removed, since healing matches it, and for Clone with it kept) and whose inside is smoothest. The photo is measured uncropped with the spots already there, so a spot doesn't take another's dust. Both steps are one undo step.
- The tool opens from the toolbar or Photo › Spot Removal (Q, as in Lightroom). Its controls take the inspector's place, as the crop tool's do: Heal or Clone, Size, Feather and Opacity. They change the selected spot, and the next spot takes the last values. Size shows the spot's width in pixels of the photo, on a track spaced by ratio; [ and ] change it on the photo. Zoom stays on, since dust is small: pinching zooms and the space bar held pans, as on the canvas the tool covers. The tool's keys are read from the window, so they work after a click on a slider or the photo.
- An edit without spots renders as before, so `processVersion` stays 1.

## Consequences
- Changing lens corrections or perspective after placing spots moves the photo under them, since spots are placed after both. Placing them on the raw decode would avoid that, but the decoder's own lens profile correction can't be undone to map a click back.
- Heal matches brightness and color only on average over the circle. A source with a strong edge carries the edge in, as Clone would; moving the source fixes it.
- A spot's source is chosen by measuring the photo. The measuring reuses the canvas's decode when the spot is 4 to 40 pixels across at its scale, which takes about 0.1 s on a 60 MP DNG; otherwise it decodes again, about 0.6 s. The source circle shows once it is chosen.
- Spot Removal is an item in Copy Settings, unticked by default, so dust can be copied to other photos from the same shoot. Pasting replaces the target's spots. Spots are placed on the photo as the camera oriented it, so dust from a landscape photo lands in the wrong place on a portrait one.
