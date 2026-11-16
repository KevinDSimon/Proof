# 0042. App icon

Date: 2026-11-16
Status: Accepted

## Context
Issue #194: Proof had no app icon, so the Dock and Finder showed the generic one. The icon is a P whose bowl is a lens with five aperture blades, drawn in white on near-black. The source drawing placed it on its own rounded square, 912 points on a 1024-point canvas, which is not the macOS icon shape or grid.

## Decision
- The icon is an Icon Composer file, `App/Proof/AppIcon.icon`, rather than PNGs in the asset catalog. macOS applies the icon shape and the margin around it, and draws the dark, clear and tinted appearances from the same file. The build turns it into every size macOS needs.
- It is flat: a solid fill of #131313 and one layer, `aperture-p.svg`, the P and its blades in flat white. Glass, specular highlights, the layer shadow and translucency are off. macOS still adds the edge and shadow it gives every app icon. The drawing's mask and repeated blade were written out as plain paths so the layer has no masks or `<use>` elements. The layer keeps the source drawing's coordinates and is scaled by 1024/912, so the mark keeps its size relative to the icon's edge.
- `ASSETCATALOG_COMPILER_APPICON_NAME` is `AppIcon` in both configurations.

## Consequences
- The icon is edited in Icon Composer (in Xcode's Applications folder), or by replacing `aperture-p.svg`.
- The icon is black, white and gray, like the interface. It doesn't use the highlight color.
