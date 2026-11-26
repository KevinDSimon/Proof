# 0051. iPad and iPhone serve a mobile workflow

Date: 2026-11-26
Status: Accepted. Supersedes 0048's rule that new features land on every platform.

## Context
Issue #276. Decision 0048 made new features land on Mac, iPad and iPhone, and gave the iOS app the Mac's adjustments and tools one for one. Building it showed what that costs. Each Mac feature needs its own touch design, and a copy of the Mac's controls on a phone is often worse than a smaller design. The Mac's export sheet, with every format, size and color space choice, is one example. The white balance eyedropper, which needs a clear way to confirm a pick by touch, is another.

People use a phone or iPad differently from a Mac. On the go they cull, rate, make quick edits and share a photo now and then. Careful editing, batches and exports to folders happen back at the desk. Edits are kept in XMP sidecars next to the photos, so an edit started on one device opens on another wherever the folder is shared, such as in iCloud Drive or on a server.

## Decision
- iPad and iPhone are for a mobile workflow: browse, cull, rate and flag, quick edits, and sharing a photo now and then. The work is picked up on the Mac for detailed editing and export. The Mac is the complete app.
- New features are designed for the Mac first. iPad and iPhone get a feature when it serves the mobile workflow. It is then designed for that workflow, not copied from the Mac: fewer choices, sensible defaults, one hand on iPhone, and done in a few taps. A Mac feature that doesn't serve the mobile workflow stays on the Mac, and its issue says so.
- An edit made on any device is saved in the same recipe and sidecar and renders the same everywhere. `ProofKit` stays shared and platform-neutral, so iOS never needs its own engine.
- Shared views stay in `ProofUI` where one design suits both. When the mobile workflow needs a simpler design, the iOS app gets its own view over the same model.
- Features already built for iPad and iPhone stay. Each iOS flow (browse, edit, crop, masks, export) may later be reviewed against the mobile workflow and simplified in its own issue. Export (#234) continues as 0048 describes.
- The rest of 0048 stands: one universal app, its navigation, its layout and Proof's interface rules.

## Consequences
- A Mac feature no longer needs a paired iOS issue, and the iPad and iPhone milestone holds only work that serves the mobile workflow.
- The iOS app will have fewer features than the Mac. Something added on the Mac may not show on iOS, though an edit made with it still renders the same on iOS.
- Each iOS feature takes a design decision, written in its issue, about what the mobile workflow needs.
