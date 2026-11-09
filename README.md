# Proof

A Mac RAW photo editor built on Core Image. It edits photos where they already live (a local folder, an external drive or a NAS), saves edits in a sidecar next to each file, and never changes the original.

Status: pre-alpha. Nothing to download yet.

## v1 scope

- Folders panel with an All Photos view across every saved folder and its subfolders, and a filmstrip, with a star filter that reads ratings from XMP sidecars (written by Photomator, Lightroom, Capture One and others)
- Lightroom's Basic panel: temperature, tint, exposure, contrast, highlights, shadows, whites, blacks, vibrance, saturation
- Tone curve (RGB and per channel) and a histogram
- `.cube` LUTs with a strength slider
- Crop, straighten, before/after, copy and paste settings, undo
- Export to JPEG, HEIC and TIFF

After v1: Texture, Clarity and Dehaze (v1.1), then masks as layers (v1.2). An iPad and iPhone version comes after the Mac app. See [docs/roadmap.md](docs/roadmap.md).

## Repository layout

| Path | What it is |
| --- | --- |
| `App/Proof.xcodeproj` | The Mac app (SwiftUI, App Sandbox on). Depends on the local `ProofKit` package. |
| `App/Proof` | The Mac app's source files and entitlements |
| `Sources/ProofKit` | Platform-neutral engine: edit recipe, render pipeline, sidecars, XMP, LUT parsing. No AppKit, UIKit or SwiftUI. |
| `Tests/ProofKitTests` | Tests for ProofKit (Swift Testing) |
| `docs/` | Architecture, edit file format, roadmap and decision records |
| `CLAUDE.md` | Rules for AI agents working in this repo |

## Building

Requires macOS 27 and Xcode 27 or later on Apple Silicon. The app targets macOS 27 and, later, iOS 27.

To build and test the engine from the command line:

```bash
swift build
swift test
```

RAW files are never committed, so the test that renders a real photo runs only when `PROOF_SAMPLE_DNG` names one:

```bash
PROOF_SAMPLE_DNG=~/Pictures/L1000725.DNG swift test
```

To run the Mac app:

1. Open `App/Proof.xcodeproj` in Xcode. Xcode resolves the `ProofKit` package from the repository root.
2. Choose the **Proof** scheme and **My Mac** as the destination.
3. Choose Product > Run (⌘R). Press ⌘O and choose a folder of RAW photos, select a photo and press Return to edit it.

The app is signed to run locally, so no Apple developer team is needed. To build it without Xcode's interface:

```bash
xcodebuild -project App/Proof.xcodeproj -scheme Proof build
```

## Contributing

Work is tracked in GitHub Issues, grouped into milestones by phase. Each change goes through a pull request that closes its issue, passes CI and updates the docs it affects. See [CLAUDE.md](CLAUDE.md) for the conventions; they apply to people and agents alike.
