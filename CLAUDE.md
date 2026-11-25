# Working on Proof

Proof is a Mac RAW photo editor in Swift, built on Core Image and Metal. These rules apply to every agent and person working in this repository.

## Workflow

- Every change starts from a GitHub issue. Branch from `main` as `<issue-number>-<short-slug>` (e.g. `12-exposure-slider`).
- Every issue belongs to a milestone, set when it's filed: the release it must ship in, or `Later` if it isn't scheduled. Bugs go in the release they must be fixed before; there is no separate bug milestone, and the `bug` label lists them across releases.
- Open a pull request whose description says `Closes #<issue>`, what changed, and how it was tested. Fill in the PR template.
- Never push to `main` directly. `main` only changes through merged pull requests.
- Keep pull requests small: one issue, one concern. Split work that touches unrelated areas.
- Commit messages are short and name the issue: `Exposure slider through CIRAWFilter (#12)`.

## Before opening a pull request

- `swift build` and `swift test` pass.
- A change to rendering, export, opening a photo, or what renders during a slider drag, zoom or pan also passes the timing run in CONTRIBUTING.md. It takes about 9 minutes and uses the GPU, so tell the person before starting it, saying why and how long it will take. When it isn't clear whether a change affects rendering, ask whether to run it.
- New behavior has a test. Pipeline changes that alter pixels update or add a reference render in the same PR, and the PR says which renders changed and why.
- Docs that describe the changed behavior are updated in the same PR: `docs/architecture.md`, `docs/edit-format.md`, `README.md`, or a new decision record in `docs/decisions/`.

## Architecture rules

- `ProofKit` is platform-neutral. It never imports AppKit, UIKit or SwiftUI, so the iPad and iPhone app can reuse it.
- Folder and file access goes through one `FileAccess` abstraction (added in Phase 1), never raw paths scattered through the code. Sidecars are read and written with `NSFileCoordinator`.
- Rendering always takes a target size. Nothing renders a full 60 MP image except export.
- No change may alter how an existing saved edit renders without bumping `EditRecipe.processVersion`. Old versions keep rendering as they did.
- The edit recipe format is documented in `docs/edit-format.md`. Any change to it updates that document and adds a migration test.
- Every new adjustment or tool that changes the recipe is added to Copy Settings (`SettingsItem`) in the same PR. Settings that fit only the photo they were made on, such as Transform, Crop and Spot Removal, start unticked.
- Original photos are never written to. Ratings and flags are written only to XMP sidecars (#52), keeping every other tag in them.

## Mac, iPad and iPhone

Proof is one app on Mac, iPad and iPhone (see `docs/decisions/0048-ipad-iphone-app.md`). New features land on every platform.

- Write a feature once. Engine work goes in `ProofKit`; the app model and views both apps can share go in `ProofUI`. Only what really differs by platform lives in an app target: pointer versus touch and Pencil input, menus versus touch-and-hold, the Mac inspector versus the iPhone sheet.
- When the whole feature fits one small PR, it ships on all platforms in that PR.
- When it doesn't, split it by layer: one issue for the engine and shared parts plus the first platform, and a paired issue for the other platform's input and layout. File both when the work is planned, in the same milestone, linked to each other. The milestone isn't done until both are closed. Never park the other half in `Later`.
- Until the iOS app has the area a feature belongs to (for example, its inspector), add the feature to the `Done when` list of the iOS issue for that area instead of filing a new one.
- A feature meant for one platform only, such as Show in Finder or Pencil hover, says so in its issue.

## Interface

- Follow Apple's Human Interface Guidelines for the current macOS. Use standard SwiftUI views and modifiers (`NavigationSplitView`, `List` sidebars, `.inspector`, toolbars, `ContentUnavailableView`, `confirmationDialog`, menu commands) before building custom ones. Build a custom view only when SwiftUI has no equivalent, such as the filmstrip.
- Panels and controls sit beside the photo, never on top of it. The photo sits centered on a neutral canvas, with a margin, inside the safe area. The interface is dark in both system appearances. The canvas is 13% gray by default and can be set to another color with View › Canvas Color (see `docs/decisions/0036-dark-interface-canvas-color.md`); only the canvas takes that color. It runs under the toolbar glass; the photo never does (no `backgroundExtensionEffect`). Overlays are only for temporary or on-image tools, such as crop handles or a before/after split, and for the small rating and flag badges on thumbnails.
- The interface itself is black, white and gray, with one highlight color, #FFD52E (`Color.highlight`), for small marks of state only: switches, the selection outline and the focused sidebar selection (see `docs/decisions/0041-yellow-highlight.md`). Never use it for fills, slider tracks or anything large beside the photo. Selection is marked with a rounded outline or an inverted row, not a colored fill.
- Browsing and editing are separate modes, as in Photos. Browsing controls such as the filter appear only while browsing; editing controls only while editing.
- Show folders as they are on disk. Proof doesn't group or reorganize the person's files. All Photos is the one view across folders; it reads them but changes nothing on disk (see `docs/decisions/0006-all-photos.md`).

## Conventions

- Match the surrounding code's naming, structure and comment density. Comments explain constraints the code can't show, not what the next line does.
- Tests use Swift Testing (`@Test("A sentence describing the behavior")`, `#expect`).
- No third-party dependencies without a decision record explaining why Apple's frameworks aren't enough.
- Docs are plain and specific: complete sentences, no superlatives, no marketing language.

## Working within a budget

- One issue per agent session. When it's done, summarize where things stand in the PR and stop.
- Read what you need: search before opening long files, and don't re-read unchanged files.
- If an issue turns out larger than described, say so in the issue and propose a split before continuing.
