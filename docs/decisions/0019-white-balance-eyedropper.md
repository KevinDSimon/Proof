# 0019. White balance eyedropper by rendering the picked patch

Date: 2026-11-10
Status: Accepted

## Context
Issue #71 adds an eyedropper to the White Balance card: click something that should be neutral gray, and the temperature and tint are set so it is. Lightroom, Capture One and Photos all have one. `CIRAWFilter.neutralLocation` sets the white balance from a point, but it takes the point in the sensor's own coordinates, before orientation, turning, straightening and cropping, and it would give the result only as new filter settings to read back. Auto white balance (decision 0018) already finds a temperature and tint by rendering and measuring a cast, in the photo's shown coordinates.

## Decision
- The eyedropper uses the same search as Auto white balance, `AutoAdjust.whiteBalance`, with a different measurement: the plain mean color of a small patch around the click, in linear light, rather than a weighted gray world over the photo. The patch is rendered alone, at a scale that makes it about 8 pixels across, up to full resolution, with every adjustment other than white balance, detail and crop at its default, so looks and color adjustments don't change what is measured.
- The patch is 5 screen pixels across, or 4 photo pixels when zoomed far in, so it follows the zoom: at Fit it averages a larger area, and zoomed in it can pick a small gray object.
- The search starts from the camera's white balance, not the current one. A white balance far from the right one can push a channel of the patch below zero in the extended linear space, where its color can't be measured. Starting from As Shot also means picking the same spot always gives the same result.
- A patch whose brightest channel is under 0.2% is too dark to tell its color. The pick beeps and the eyedropper stays open for another try.
- The result is written as ordinary Temperature and Tint values, rounded as Auto's are, and the menu shows Custom. It is one undo step. `processVersion` stays 1 and the edit format doesn't change.
- As in Lightroom with Auto Dismiss on, one click closes the eyedropper. W or the button opens it; Esc, W's menu item, or the button closes it. While it is open, the pointer is a crosshair and a loupe beside it shows the 11 × 11 pixels under it, as the canvas shows them, with the center pixel outlined and its red, green and blue as percentages of the display's range. Zoom keeps working from the keyboard and the navigator; dragging to pan doesn't, because a click picks.

## Consequences
- A pick takes about as long as Auto white balance, under a second on the sample photo, because each step of the search renders the patch again. The loupe shows a spinner meanwhile.
- A blown-out patch has no recorded color. It is measured like any other and gives a white balance that makes the clipped values neutral, which changes little; the loupe's values near 100% show why.
- The loupe's RGB values are in the display's color space after all adjustments, not in Lightroom's ProPhoto-based space, so they are a guide to neutrality rather than numbers to compare with Lightroom's.
