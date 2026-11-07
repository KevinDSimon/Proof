# Proof

A Mac RAW photo editor built on Core Image. It edits photos where they already live (a local folder, an external drive or a NAS), saves edits in a sidecar next to each file, and never changes the original.

Status: pre-alpha. Nothing to download yet.

## v1 scope

- Folders panel and filmstrip, with a star filter that reads ratings from XMP sidecars (written by Photomator, Lightroom, Capture One and others)
- Lightroom's Basic panel: temperature, tint, exposure, contrast, highlights, shadows, whites, blacks, vibrance, saturation
- Tone curve (RGB and per channel) and a histogram
- `.cube` LUTs with a strength slider
- Crop, straighten, before/after, copy and paste settings, undo
- Export to JPEG, HEIC and TIFF

After v1: Texture, Clarity and Dehaze (v1.1), then masks as layers (v1.2). An iPad and iPhone version comes after the Mac app. See [docs/roadmap.md](docs/roadmap.md).

## Repository layout

| Path | What it is |
| --- | --- |
| `Sources/ProofKit` | Platform-neutral engine: edit recipe, render pipeline, sidecars, XMP, LUT parsing. No AppKit, UIKit or SwiftUI. |
| `Tests/ProofKitTests` | Tests for ProofKit (Swift Testing) |
| `docs/` | Architecture, edit file format, roadmap and decision records |
| `CLAUDE.md` | Rules for AI agents working in this repo |

The Mac app target is added in Xcode in Phase 0 and depends on `ProofKit`.

## Building

Requires Xcode 16 or later on Apple Silicon.

```bash
swift build
swift test
```

## Contributing

Work is tracked in GitHub Issues, grouped into milestones by phase. Each change goes through a pull request that closes its issue, passes CI and updates the docs it affects. See [CLAUDE.md](CLAUDE.md) for the conventions; they apply to people and agents alike.
