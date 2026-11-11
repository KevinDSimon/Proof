# 0024. Manual distortion and lens vignetting

Date: 2026-11-11
Status: Accepted

## Context
Issue #79 adds Lightroom's manual lens corrections to the Lens Corrections card: a Distortion amount and a Vignetting amount and midpoint. Leica M DNGs carry no correction profile, and lensfun's coverage of the 21 Super-Elmar and the 35 and 50 Summicron is too thin to use (see #78), so these sliders are how those lenses get corrected. Unlike the other sliders, distortion moves pixels instead of changing their color, and correcting it leaves parts of the frame with no picture: the middles of the sides when correcting barrel distortion, the corners when correcting pincushion.

## Decision
- Distortion uses a one-term radial model about the center of the uncropped photo: the pixel at distance `r` from the center, in units of the half diagonal, is read from `r × s × (1 + k r²)`. Distortion runs from -100 to 100 and sets `k = -0.2 × amount / 100`, so positive values correct barrel distortion, as in Lightroom. Lightroom doesn't publish its model, so the range was chosen to cover strong wide-angle distortion with fine steps for subtle lenses, not matched value for value. Keeping `k` above -1/3 keeps the model one-to-one.
- The photo always fills the frame. `s` is the largest scale at which the frame's corners and the middles of its sides, the only points that can reach past the photo under this model, still read from inside it. Lightroom's Constrain Crop switch, which can show the empty edges, isn't offered: the crop tool covers any further framing, and an option to show empty edges would need the crop to handle them.
- Lens vignetting brightens or darkens each pixel like exposure by `amount / 100 × 2 × r^p` stops, round about the uncropped photo's center, where `p = 2^(2.6 × midpoint / 100)`: 1 at Midpoint 0, about 2.5 at 50, close to a lens's natural falloff, and 6 at 100. Amount 100 brightens the corners by 2 stops. It works in floating point in linear light, so it can't band.
- Both run right after chromatic aberration, before every tone adjustment: lens vignetting first, since the lens's falloff is centered where the sensor recorded it, then distortion. Both are Metal kernels compiled on first use, and both work in fractions of the photo's size, so they apply at any render size. The crop comes later and is normalized, so it frames the corrected photo.
- While the Distortion slider is dragged, a square grid is drawn over the photo, as in Lightroom, so lines in the photo can be lined up against straight ones. Its squares are a twelfth of the photo's short edge and its middle lines run through the photo's center, where the correction moves nothing, so a 3:2 or 4:3 photo fits whole squares. It is a temporary tool, so it may sit on the photo, and it uses the crop tool's grid style.
- The card gets a switch like the other cards (`AdjustmentGroup.lens`). Off shows the photo without any lens correction, the profile included, and changes nothing in the edit. Unlike Vignette and Detail it starts on, since turning it off would remove the profile from photos whose decoder applies it by default.
- The settings live in `lens.distortion` and `lens.vignetting`. `null` or missing values render as before, so `processVersion` stays at 1. Remove Chromatic Aberration measures the photo without them, since its correction comes first.

## Consequences
- Lenses with wavy (mustache) distortion are only partly corrected; that would need a second term.
- Correcting distortion enlarges the photo slightly, so a little of its edge is lost, more for stronger settings.
- Brightening the corners can push bright areas there past white, as in Lightroom; the tone sliders that follow can bring them back.
