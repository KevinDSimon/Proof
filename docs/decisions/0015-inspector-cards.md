# 0015. Inspector sections as cards with a switch

Date: 2026-11-10
Status: Accepted

## Context
Issue #98. The inspector was a grouped SwiftUI `Form`: each section's title and Reset sat above its card, and only Curve and Looks had a switch to compare with and without them. On macOS 26 a grouped form draws pop-up buttons as plain text with arrows, without the filled background they have elsewhere, such as in Finder's settings. The owner wants each adjustment group laid out as Pixelmator Pro does on iPhone and iPad: the title inside the card, Reset beside a switch that turns the group on or off.

## Decision
- Each adjustment group is an `InspectorCard`: a rounded card with its title inside, Reset, and a switch. Histogram has a card without Reset or a switch. The cards are laid out by hand in a `ScrollView`, not in a `Form`, so pop-up buttons keep their filled background.
- The switch turns the group's adjustments on or off and opens or closes its card. Off shows the photo without them, to compare; it changes only the view, not the edit, and isn't saved, as the Curve switch worked before. Editing a curve or choosing a look turns its group back on.
- When a photo opens, White Balance, Light and Color are on. Curve and Looks are off, so their larger controls stay closed, unless the photo already has a curve or a look.
- The card is a step lighter than the canvas in the dark appearance (18% gray) and darker in the light (95%), neutral like the canvas. Its corners are continuous with a 14 pt radius, about the grouped form's cards, with 16 pt inside, between cards and from every edge of the panel. Reset is in the primary label color while it can be used, so it reads as available rather than in the gray accent.
- The card's title is the headline; each slider's name is the primary label color at 75% and its value the primary, a step between primary and secondary, which macOS has no named color for, so the title reads first.
- The crop tool's panel is one Crop card, with Rotate and Flip inside it rather than a card of its own, and Reset but no switch: the tool already shows the whole photo, and Done or Cancel is the comparison. Both panels share `InspectorPanel`, the scrolling column of cards.

## Consequences
- A group that is off renders as if its adjustments were neutral: white balance as shot, the Light and Color sliders at 0, no curve, no look. Thumbnails and the saved edit always include every group.
- Turning a group off and opening another photo turns it back on there, which may surprise someone who turned White Balance off to compare across photos.
