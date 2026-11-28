# 0060. Soft scroll edge under the top bar on iPad and iPhone

Date: 2026-11-28
Status: Accepted

## Context
On iPad and iPhone, scrolling content meets the navigation bar's glass at its top edge. The iPhone tool sheets set the system's soft edge explicitly, so sliders fade out beneath the bar. The other screens, such as the library, the grid, History, Copy Settings and Export, used the automatic style, so they weren't sure to match. The iPad inspector column already hid its top edge, because the blur showed over that one column of several under the toolbar. The Mac grid sets a hard edge, so its title bar looks the same with or without photos (#322).

## Decision
Every iOS scroll view under a navigation bar uses one modifier, `softTopScrollEdge()` in `ProofUI`, which sets the soft top edge. It does nothing on the Mac, which keeps the edges it sets itself, including the grid's hard edge.

The iPad inspector column keeps its hidden edge. It sits beside the photo, which doesn't scroll and stops at the bar, so a soft blur over the cards alone drew a band across one column only. The cards stop at the bar instead, and the gray behind them still runs under it. On iPhone the inspector isn't shown; the tool sheets take its place and have the soft edge.

## Consequences
- Scrolling under the top bar fades out the same way on every iPad and iPhone screen that scrolls.
- A new iOS screen that scrolls under a navigation bar adds `softTopScrollEdge()`.
- The inspector column on iPad is the one exception, and its view says so.
