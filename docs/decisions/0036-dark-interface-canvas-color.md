# 0036. An always-dark interface with a choice of canvas color

Date: 2026-11-15
Status: Accepted

## Context
Since #38 the window followed the system appearance in Browse and Edit, and the canvas with it: white in light, 13% gray in dark ([0004](0004-window-layout.md), amendment of 2026-11-08). In the light appearance the photo was judged against a white surround, which makes it look darker, and the bright sidebar and inspector competed with it. Lightroom and Capture One keep their interface dark and let the surround behind the photo be changed instead.

## Decision
Proof's interface is dark in both system appearances. `NSApplication.appearance` is set to dark when the app starts, so the sidebar, grid, inspector, toolbar, menus, sheets and the color panel all follow.

View › Canvas Color sets the color around the photo in Edit: Dark Gray (13% gray, the default), Black, Middle Gray (46%, 18% reflectance), White, or Custom…, which opens the system color panel. The choice is a `CanvasColor` in `ProofKit`, stored in `UserDefaults` and kept across photos and launches. Custom colors are kept in Display P3, the space the Metal canvas draws in, so the canvas and the SwiftUI backdrop around it meet without a seam.

Only the canvas takes the color. The thumbnail grid, sidebar, inspector and the Navigator's plate keep the interface's 13% gray, and the crop tool fades the photo outside the rectangle toward the canvas color.

## Consequences
- The photo is shown against the same calm surround whatever the system appearance, and can still be checked on white or any other color.
- Proof no longer follows the person's light appearance. Code that chooses colors by `colorScheme` still works, but only its dark branch is reached.
- With a white or light canvas, the toolbar glass and the filmstrip in Edit sit over a light surface; they remain dark controls on it.
