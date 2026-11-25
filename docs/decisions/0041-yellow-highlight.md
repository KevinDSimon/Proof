# 0041. One highlight color, #FFD52E

Date: 2026-11-16
Status: Proposed

## Context
Proof's interface has been black, white and gray, with the system green on switches as the only exception. Selection was a white outline or a gray row, which reads clearly but gives the app no color of its own. A single accent used in small places can mark state without biasing how the photo's colors are judged, as long as it never fills a large area or sits beside the photo.

## Decision
The interface has one color, #FFD52E, as `Color.highlight` (#192). It is used for:

- Switches that are on, in place of the system green.
- The selection outline around thumbnails in the grid, the filmstrip, the Looks card and the navigator.
- The selected row in the sidebar while the sidebar has focus, as in Notes. The `AccentColor` asset is a darker yellow, #9A843A, so the row's white text stays readable; the full highlight behind white text can't be read. When focus moves to the grid, the row turns gray. Picking a sidebar row leaves focus in the sidebar; the grid takes it when a photo is clicked, on Tab, or when coming back from Edit with a photo selected. Before, the grid took focus whenever it appeared, so the row was gray almost at once.

Standard controls that use the accent color take the darker yellow too, such as focus rings. Sliders are tinted 40% gray (`Color.sliderFill`) so they stay gray. As with any app accent color, macOS shows it only while the system accent color is Multicolor; with another system accent, that color shows instead.

Slider tracks, buttons, the canvas, the inspector cards and toolbar items don't use the highlight.

## Consequences
- On and off, and what is selected, show in one consistent color.
- The switch's white knob has less contrast on yellow than on green; the switch still reads by the knob's position.
- New places for the highlight should be small marks of state. A filled area in the highlight needs black, not white, text on it.

## Amendment (#225)

On iPad and iPhone, the checkmark button that ends Select in the grid is filled with the highlight color, with a dark checkmark, as Notes fills its own. It is the only filled use. It marks the one way out of a temporary mode and sits in the toolbar, away from the photos.
