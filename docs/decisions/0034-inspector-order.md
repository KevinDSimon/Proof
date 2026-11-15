# 0034. Order of the adjustments inspector

Date: 2026-11-15
Status: Accepted

## Context
Issue #161 asks whether the order of cards in the adjustments inspector follows a sensible editing workflow. The cards were added one phase at a time, each below the last, so the order reflects when they were built rather than when they are used. Card order changes only the panel; the pipeline's processing order is separate, and no saved edit renders differently.

The order before this decision: Histogram, Info, White Balance, Basic (tone, Texture, Clarity, Dehaze, Black & White, Vibrance, Saturation), Selective Color, Curve, Detail, Lens Corrections, Transform, Effects (Vignette, Grain, Halation, Bloom) and Looks.

## Decision
The owner chose this order:

1. Histogram
2. Info
3. Looks
4. White Balance
5. Basic
6. Curve
7. Selective Color
8. Detail
9. Lens Corrections
10. Transform
11. Effects

- Looks moves from the bottom to just above White Balance. A look is usually where an edit starts, and the other adjustments refine it. Looks starts off and closed unless the photo has a look, so on most photos it adds one row above White Balance.
- Curve moves above Selective Color, so tone comes before color.
- Which cards start open doesn't change: White Balance, Basic and Lens Corrections are on; the others start off unless the photo uses them (`AdjustmentGroup.initiallyOff`). Lens Corrections stays on because its switch also turns off the lens profile corrections read from the file.
- Crop and straighten stay a separate tool rather than a card. The crop tool needs the whole photo on the canvas, and Done or Cancel is its comparison.
- Vignette stays in Effects and lens vignetting in Lens Corrections.
- Every card in the adjustments inspector folds with a disclosure arrow beside its title, as the Info card does. This changes decision 0015, where the switch alone opened and closed a card, so a card in use couldn't be put out of the way without hiding its adjustments from the photo. Now:
  - A click on the arrow, the title or the empty space beside it folds or unfolds the card; Reset and the switch keep their own clicks. A folded card that is on keeps its adjustments on the photo.
  - A card that is off is closed, as before. Unfolding it turns it on, since an off card has nothing to show.
  - Turning a card's switch on unfolds it, so the controls just turned on are visible.
  - Folded cards stay folded from photo to photo and across launches, so the panel is set up once. Histogram folds too. The crop tool's single Crop card doesn't fold.

The reordering itself is #177.

## Consequences
- Choosing a look first and then adjusting White Balance and Basic reads top to bottom.
- A photo with a look opens with the Looks card's previews above White Balance, pushing the tone sliders down. Folding the card puts them away and keeps the look.
- Each card's header has one more control. The arrow is the system's, in the interface's gray.
- Presets (v1.2) set several cards at once, so where they appear is decided with that work, not here.
