# 0046. Card switches are saved in the edit

Date: 2026-11-20
Status: Accepted. Supersedes the switch rule in 0015.

## Context
Issue #200. Under decision 0015 a card's switch changed only the canvas: the edit kept the adjustments, the filmstrip and grid thumbnails and export still showed them, and opening the photo again turned every switch back on. Switching Looks off changed the canvas but not the filmstrip, which read as a bug. The issue weighed two fixes: thumbnails that follow the switches, which would show something that isn't saved while export still included the adjustments, or switches saved in the edit, as Lightroom saves its panel switches.

## Decision
- The recipe stores `switchedOff`, the cards whose switch is off. Their adjustments stay in the edit but don't render. `EditRecipe.rendered` leaves them out, and `RAWRenderer.apply` uses it, so the canvas, thumbnails, export, Auto and the subject mask all see the same photo.
- Switching a card off or on is one undo step, named "Look Off" or "Look On" in the History panel, and is saved like any other change.
- A card at its defaults has nothing to leave out, so its switch only closes the card and isn't saved. Cards that start closed when a photo opens (Selective Color, Curve, Detail, Transform, Effects and Looks with no adjustment) stay a view default, as before. Lens Corrections off renders without the lens profile, so it is always saved.
- An edit counts as neutral only when no switched-off card changes the render, so a photo whose Curve is off at its defaults has no sidecar, and one with Lens Corrections off keeps one.
- Copy Settings carries each card's switch with its items: pasting any item of a card sets that card's switch to the copied photo's. Cards with no copied item keep their switch. Copy Settings gets no separate checkbox for switches, because a switch belongs to its card.
- Show Original keeps the Lens Corrections and Transform switches with their values, so the comparison frames the same picture.
- Edits saved before this have no `switchedOff` and open with every card on, which is how they rendered. `processVersion` stays 2, because no saved edit renders differently. `formatVersion` stays 3, because the field is new rather than renamed.

## Consequences
- The canvas, filmstrip, grid and export always agree.
- A photo can carry adjustments that don't show. The card stays off when the photo is opened again, so its adjustments can be found and switched back on.
- A version of Proof from before this ignores `switchedOff` and renders switched-off cards. It keeps the field when it saves, since `Sidecar` keeps fields it doesn't recognize.
