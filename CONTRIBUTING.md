# Contributing to Proof

Every change starts from a GitHub issue and goes through a pull request. [CLAUDE.md](CLAUDE.md) has the full conventions; they apply to people and AI agents alike.

## Workflow

1. Pick or open an issue.
2. Branch from `main` as `<issue-number>-<short-slug>`, for example `12-exposure-slider`.
3. Keep the pull request to one issue. Its description says `Closes #<issue>`, what changed and how it was tested.
4. `swift build` and `swift test` pass, and CI passes.
5. New behavior has a test, and docs that describe the changed behavior are updated in the same pull request.

## Requirements

A Mac with Apple silicon, macOS 27 and Xcode 27 or later.

## Running the tests

```bash
swift build
swift test
```

`ProofKit` also builds for iOS, and CI runs its tests on an iPhone simulator. To do the same locally, name any iPhone simulator that Xcode has installed:

```bash
xcodebuild test -scheme Proof -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

RAW files are never committed, so the tests that render a real photo run only when `PROOF_SAMPLE_DNG` names one:

```bash
PROOF_SAMPLE_DNG=~/Pictures/L1000725.DNG swift test
```

Reference renders of that photo, with no edit and with an edit, are kept as PNGs in `Tests/ProofKitTests/References` together with a fingerprint of the photo. They are compared only when `PROOF_SAMPLE_DNG` names the same photo. After a change that is meant to alter pixels, record them again and say in the pull request which renders changed and why:

```bash
PROOF_SAMPLE_DNG=~/Pictures/L1000725.DNG PROOF_RECORD_REFERENCES=1 swift test --filter ReferenceRenderTests
```

The tests whose job is timing, such as reading, rendering and exporting that photo or a slider change at full-screen size, run only when `PROOF_TIMING` is set, so a normal run stays short. The histogram and spot source tests check their results in every run and check their times only with `PROOF_TIMING`. Run all of them on their own, one at a time, since other tests rendering at the same moment slow them down:

```bash
PROOF_SAMPLE_DNG=~/Pictures/L1000725.DNG PROOF_TIMING=1 swift test --no-parallel --filter "Timing|picksSourceOnRealPhoto|measuresSample"
```

The run takes about 9 minutes, most of it the two export timings. Run it before a pull request that changes:

- the render pipeline: an adjustment, a filter, masks, or how Core Image is used
- export
- how a photo is opened or decoded
- what is rendered while a slider is dragged or the photo is zoomed or panned

It isn't needed for interface-only changes, recipe or sidecar changes that don't affect rendering, or docs. For those, `swift test` and the run with `PROOF_SAMPLE_DNG` are enough. Close other apps that use the GPU while it runs, since they slow the renders and can make a time check fail. Say in the pull request whether the timing run was made and what it showed.

To compare Highlights and Shadows with Core Image's `CIHighlightShadowAdjust`, point `PROOF_COMPARE_DIR` at a folder of RAW photos. The test writes one strip per photo and method to `PROOF_COMPARE_OUTPUT`, or to a temporary folder:

```bash
PROOF_COMPARE_DIR=~/Pictures/Compare PROOF_COMPARE_OUTPUT=~/Desktop/compare swift test --filter comparisonStrips
```

## Running the app

Open `App/Proof.xcodeproj`, choose the **Proof** scheme and **My Mac**, and choose Product › Run (⌘R). Xcode resolves the `ProofKit` package from the repository root. The app is signed to run locally, so no Apple developer team is needed. To build it without Xcode's interface:

```bash
xcodebuild -project App/Proof.xcodeproj -scheme Proof build
```

Release builds for testers are signed and notarized by `scripts/release.sh`; see [docs/releasing.md](docs/releasing.md).

## Repository layout

| Path | What it is |
| --- | --- |
| `App/Proof.xcodeproj` | The Mac app (SwiftUI, App Sandbox on). Depends on the local `ProofKit` package. |
| `App/Proof` | The Mac app's source files and entitlements |
| `App/Version.xcconfig` | The app's version and build number |
| `Sources/ProofKit` | Platform-neutral engine: edit recipe, render pipeline, sidecars, XMP, LUT parsing. No AppKit, UIKit or SwiftUI. |
| `Tests/ProofKitTests` | Tests for ProofKit (Swift Testing) |
| `docs/` | Architecture, edit file format, release steps, roadmap and decision records |
| `scripts/release.sh` | Builds a signed, notarized `.dmg` for a release |
| `CLAUDE.md` | Rules for AI agents working in this repo |
