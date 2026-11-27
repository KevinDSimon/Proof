# 0056. Accessibility on iPad and iPhone

Date: 2026-11-26
Status: Accepted. Carries out the accessibility part of 0048.

## Context
Issue #237. Decision 0048 says every control and badge has a VoiceOver label, lists and the inspector follow Dynamic Type, Reduce Motion is respected, and touch targets are at least 44 points. Most of the interface already met this: the toolbars, menus, sheets and pickers are the system's, which label themselves and follow these settings, and the thumbnails, filmstrip, canvas, histogram and curve already had labels and actions. This pass covers what the system doesn't do for Proof's own views.

## Decision
- **Sliders.** Every adjustment is an `AdjustmentSlider`. It is now one VoiceOver element with its name and value, and a swipe up or down moves it a twentieth of its travel, rounded to the slider's own step: half a stop of exposure, 10 of contrast, an even step in mireds for temperature. The system's step is a tenth, too coarse for an edit; the slider's own step would take a hundred swipes or more. An exact value can still be typed in the field beside it, which VoiceOver reads as the adjustment's value field. Reset is a VoiceOver action, as before. This is the same on the Mac.
- **Dynamic Type.** The iPhone tool sheets' compact height and the inspector sheet's small height grow with the text size, up to half the screen, so their first sliders still show. The sliders' value fields widen with it. In the grid, the accessibility text sizes allow two columns at most on iPhone and two lines for a name. On iPad, the inspector follows Dynamic Type up to the first accessibility size: past it, a card's title, Reset and switch don't fit in the column. At the accessibility sizes a card's title takes its own line above Reset and its switch, the Profile pop-up goes under its name, and the capture settings run two to a row. The iPhone tool sheets follow every size, since each row is a name and a slider.
- **Touch targets.** The system's toolbar buttons, menus and switches meet 44 points. Proof's own small controls, the cards' Reset, a mask's show and hide button, the selective color swatches and Locate in the sidebar, take taps across 44 points around them without changing their layout (`minimumTouchTarget()`). The stack count badge on a thumbnail stays small, since a larger target would take taps meant for the photo; the same command is in the thumbnail's touch-and-hold menu and is a VoiceOver action.
- **Reduce Motion.** Folding a card, the Info card, Transform's extra controls, opening a stack, the grid resizing for the Info panel and the grid and filmstrip scrolling to the current photo happen without animation. The iPad filmstrip fades in and out instead of sliding. The histogram's fade on iPhone stays, as fades are fine with Reduce Motion. The library reads the setting through `LibraryPlatform.reducesMotion` for animations it starts outside a view.
- **Contrast.** The interface's grays already meet WCAG AA: the inspector's labels, white at 75%, are about 9 to 1 on the canvas and cards. With Increase Contrast on, they are drawn white like titles. The numbers are tested in `AccessibilityMetricsTests`.

## Consequences
- What can be checked without VoiceOver is checked: the slider step, the touch target size and the contrast are tested, and the layouts were looked at in the iPhone and iPad simulators at the largest text size. VoiceOver itself needs a real device.
- The crop rectangle can't be moved with VoiceOver; the aspect ratios, Rotate, Flip and Straighten can.
