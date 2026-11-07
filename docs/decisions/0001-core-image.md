# 0001. Build on Core Image, not an existing open-source engine

Date: 2026-11-07
Status: Accepted

## Context
Proof needs RAW decoding, a Lightroom-style Basic panel, curves, LUTs and later masks. Options considered: Apple's Core Image with `CIRAWFilter`, building on Redlamp's open-source Swift and Metal engine, or a custom engine on LibRaw.

## Decision
Use Core Image and `CIRAWFilter`, with small custom Metal kernels where Core Image has no built-in filter (tone lookups, and later Texture, Clarity and Dehaze).

## Consequences
- RAW support follows Apple's camera list and updates with macOS and iOS, including Leica DNGs.
- The whole engine is understood and owned by this project, with no upstream API changes to track.
- The same engine runs on iPad and iPhone.
- Rendering quality for local contrast and dehaze depends on our own kernels, which is why those sliders are deferred to v1.1.
