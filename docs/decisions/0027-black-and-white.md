# 0027. Black and white as a Treatment with red, green and blue filters

Date: 2026-11-11
Status: Accepted

## Context
Issue #100 asks for black-and-white conversion. Lightroom mixes gray from eight color ranges, with one luminance slider per range. Photomator uses a film-filter model: each gray value is a weighted blend of the photo's red, green and blue channels, the way a colored filter on black-and-white film lightens its own color and darkens the others. Selective Color (decision 0026) already changes the brightness of each of eight ranges. Lightroom puts the choice between color and black and white in a Treatment control rather than in a separate panel.

## Decision
- The film-filter model, with three sliders, Red, Green and Blue, from −100 to +100 (owner's choice). Selective Color's Brightness is the way to lighten or darken one of the eight ranges, so a second eight-range mix would repeat it.
- A Treatment control, Color or Black & White, at the end of the Basic card, after Presence, with the color sliders under it (owner's choice), rather than a card of its own. The separate Color card is gone: Lightroom's Basic panel holds Treatment, Vibrance and Saturation too, and a "Color" control under a "Color" card title read as a repeated heading. It sits after Presence rather than at the top, as Lightroom has it, so it is beside the sliders it swaps and just above Selective Color. It has no heading: the two segments say what it is. It is a segmented control, as in Lightroom, so both choices stay in view. In Black & White the card shows Red, Green and Blue in place of Vibrance and Saturation, and Selective Color shows only Brightness. The hidden sliders keep their values and still render, and they come back with Color, so each treatment shows only the controls that are useful in it.
- Unlike the cards' switches, which only preview the photo without a group, the treatment changes the photo by itself, even with every slider at 0. It is saved in the edit as `blackAndWhite.isOn` and can be undone. Switching the Basic card off shows the photo in color, along with the card's other adjustments; there is no longer a switch for the color adjustments alone.
- The weights start from Rec. 709 luminance (0.2126, 0.7152, 0.0722), the working space's primaries, so at 0 the gray is a neutral luminance conversion. Each slider adds value ÷ 100 to its weight, and the total added is taken back from all three in proportion to luminance, so the weights add up to 1, a gray pixel keeps its value and the photo's overall brightness holds. Red +100 alone makes the gray the red channel, as a deep red filter does. Weights can go below 0, as in a channel mixer, and results below black are clamped. A first version that only scaled the weights, at most 4 times, and kept them positive made every gray an average of the pixel's channels; the muted colors of most photos have channels close together, so the sliders barely changed them (owner's report). On the sample photo the new mix changes the gray about 2.5 to 5 times as much.
- One `CIColorMatrix` after Selective Color and before the look, so vibrance, saturation and selective color still shape the gray, and a look can tone it.
- While the photo is black and white, the hue graph is measured from a small copy rendered without the mix, so it keeps showing the colors Selective Color adjusts.
- No Auto, toning or intensity control for now.

## Consequences
- Edits saved before this read as Color, so they render as before and `processVersion` stays 1.
- Three sliders can't single out a range the way Lightroom's mix can; that is left to Selective Color's Brightness, which works in display-encoded HSV hue (decision 0026).
- The strength, one channel's full weight at ±100, was chosen by reasoning and checked on the sample photo, not matched to Photomator numerically. Changing it after a release needs a new `processVersion`.
- The hue graph costs one extra small render per measured canvas render while the photo is black and white.
