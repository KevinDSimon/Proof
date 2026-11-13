# Proof

A Mac RAW photo editor built on Core Image. It edits photos where they already live (a local folder, an external drive or a NAS), saves edits in a sidecar next to each file, and never changes the original.

Status: pre-alpha. Nothing to download yet.

## v1 scope

- Folders panel with an All Photos view across every saved folder and its subfolders, and a filmstrip, with sidebar rows and a combinable toolbar filter for flags, ratings and edits that read ratings from XMP sidecars (written by Photomator, Lightroom, Capture One and others); ratings and flags set in Proof are saved to the same sidecars
- Info panel with a photo's file and camera details, and a title, caption, keywords, creator, copyright and location saved to its XMP sidecar
- Lightroom's Basic panel: temperature, tint, exposure, contrast, highlights, shadows, whites, blacks, Texture, Clarity, Dehaze, vibrance, saturation
- Selective Color: hue, saturation and brightness for eight color ranges, chosen from a graph of the photo's colors
- Black & White, chosen as the Basic card's Treatment, with red, green and blue filter sliders
- Zoom to 100% and beyond, sharpening and noise reduction
- Effects: Lightroom's post-crop vignette, film grain, halation and bloom
- Lens profile corrections, manual distortion, and perspective correction with Upright (Auto, Guided, Level, Vertical, Full)
- HSL color mixer and black and white
- Tone curve (RGB and per channel) and a histogram
- `.cube` LUTs imported into a library, with previews of the photo and a strength slider
- Crop, straighten, rotate and flip, before/after, copy and paste settings, undo
- Export to JPEG, HEIC and TIFF

After v1: film effects, then masks as layers (v1.2). An iPad and iPhone version comes after the Mac app. See [docs/roadmap.md](docs/roadmap.md).

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

RAW files are never committed, so the tests that render a real photo run only when `PROOF_SAMPLE_DNG` names one:

```bash
PROOF_SAMPLE_DNG=~/Pictures/L1000725.DNG swift test
```

Reference renders of that photo, with no edit and with an edit, are kept as PNGs in `Tests/ProofKitTests/References` together with a fingerprint of the photo. They are compared only when `PROOF_SAMPLE_DNG` names the same photo. After a change that is meant to alter pixels, record them again and say in the pull request which renders changed and why:

```bash
PROOF_SAMPLE_DNG=~/Pictures/L1000725.DNG PROOF_RECORD_REFERENCES=1 swift test --filter ReferenceRenderTests
```

To compare Highlights and Shadows with Core Image's `CIHighlightShadowAdjust`, point `PROOF_COMPARE_DIR` at a folder of RAW photos. The test writes one strip per photo and method to `PROOF_COMPARE_OUTPUT`, or to a temporary folder:

```bash
PROOF_COMPARE_DIR=~/Pictures/Compare PROOF_COMPARE_OUTPUT=~/Desktop/compare swift test --filter comparisonStrips
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
