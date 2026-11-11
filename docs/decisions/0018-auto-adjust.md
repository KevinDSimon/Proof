# 0018. Auto white balance and Auto Tone from a small render

Date: 2026-11-10
Status: Accepted

## Context
Issue #72 adds Auto to the white balance menu and an Auto button for the Tone sliders (Exposure, Contrast, Highlights, Shadows, Whites and Blacks), as in Lightroom, Capture One and Photos. `CIRAWFilter` has no automatic setting for RAW files. Whatever Auto chooses must render the same in every later version, so it can't be a setting the pipeline recomputes; it has to be ordinary slider values written to the edit. The method was tuned on the sample photo (`L1000725.DNG`, a dusk landscape with a bright sky over dark rock) and on synthetic scenes in `AutoAdjustTests`.

## Decision
- Both estimates measure the photo at about 256 pixels on the long edge, cropped as the edit crops it, in linear light, with every adjustment other than white balance, detail and crop at its default. Auto therefore ignores the Tone sliders already set, and choosing it again gives the same values.
- White balance: the color of the light is estimated as a weighted gray world. Pixels near gray count more than colorful ones, each channel is a 4-norm mean (shades of gray), and the darkest 5%, the brightest 2% and pixels near clipping are left out. The cast is measured in stops as blue against red and green against red and blue. Because the RAW decoder applies white balance before its color matrix, the temperature and tint that remove the cast are found by rendering: Newton's method on mireds and tint, starting from As Shot, with the first step judged from two small nudges and later steps refined by Broyden's method. It stops under 0.01 stops of cast or after six steps, usually after four or five renders, about 0.2 s each with the photo open (about 1 s in all). The result is rounded to 10 K and a whole tint and labelled `auto` in the edit.
- Tone: Exposure brings the log average of the middle 98% of brightness to middle gray (0.18), within ±3 stops, but stops brightening where the brightest 2% would reach 0.9, giving up at most 1.5 stops for that. The other sliders each answer one measurement of the exposed photo: Highlights pulls back a top 1% above 0.8, Shadows lifts a darkest 10% below 0.03, Whites stretches a brightest 0.1% below 0.7 toward white, Blacks deepens a darkest 0.1% above 0.004, and Contrast moves the spread of the middle 80% toward 5.5 stops. Each is limited (Highlights to −70, Shadows to +60, Whites to +40, Blacks to −40, Contrast to −20…+30) so Auto is a starting point, not a look.
- Auto writes only existing fields. `processVersion` stays 1, and edits saved by versions without Auto render as before.

## Consequences
- The estimates can change in a later version without changing any saved edit, because only their results are saved.
- Auto Tone leaves Texture, Clarity, Vibrance and Saturation alone, unlike Lightroom's Auto, which also sets some of them.
- Gray world assumes the scene averages to gray. Scenes dominated by one color, such as a sunset or a forest, will be pulled toward neutral; the white balance eyedropper (#71) is the answer there.
- The tone rules were tuned on one RAW photo. More photos may call for different thresholds.
