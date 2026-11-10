# Working on Proof

Proof is a Mac RAW photo editor in Swift, built on Core Image and Metal. These rules apply to every agent and person working in this repository.

## Workflow

- Every change starts from a GitHub issue. Branch from `main` as `<issue-number>-<short-slug>` (e.g. `12-exposure-slider`).
- Open a pull request whose description says `Closes #<issue>`, what changed, and how it was tested. Fill in the PR template.
- Never push to `main` directly. `main` only changes through merged pull requests.
- Keep pull requests small: one issue, one concern. Split work that touches unrelated areas.
- Commit messages are short and name the issue: `Exposure slider through CIRAWFilter (#12)`.

## Before opening a pull request

- `swift build` and `swift test` pass.
- New behavior has a test. Pipeline changes that alter pixels update or add a reference render in the same PR, and the PR says which renders changed and why.
- Docs that describe the changed behavior are updated in the same PR: `docs/architecture.md`, `docs/edit-format.md`, `README.md`, or a new decision record in `docs/decisions/`.

## Architecture rules

- `ProofKit` is platform-neutral. It never imports AppKit, UIKit or SwiftUI, so the iPad and iPhone app can reuse it.
- Folder and file access goes through one `FileAccess` abstraction (added in Phase 1), never raw paths scattered through the code. Sidecars are read and written with `NSFileCoordinator`.
- Rendering always takes a target size. Nothing renders a full 60 MP image except export.
- No change may alter how an existing saved edit renders without bumping `EditRecipe.processVersion`. Old versions keep rendering as they did.
- The edit recipe format is documented in `docs/edit-format.md`. Any change to it updates that document and adds a migration test.
- Original photos are never written to. Ratings in XMP sidecars are read-only until the roadmap says otherwise.

## Interface

- Follow Apple's Human Interface Guidelines for the current macOS. Use standard SwiftUI views and modifiers (`NavigationSplitView`, `List` sidebars, `.inspector`, toolbars, `ContentUnavailableView`, `confirmationDialog`, menu commands) before building custom ones. Build a custom view only when SwiftUI has no equivalent, such as the filmstrip.
- Panels and controls sit beside the photo, never on top of it. The photo sits centered on a neutral canvas, with a margin, inside the safe area. The canvas follows the system appearance: white in light, 13% gray in dark. It runs under the toolbar glass; the photo never does (no `backgroundExtensionEffect`). Overlays are only for temporary or on-image tools, such as crop handles or a before/after split, and for the small rating and flag badges on thumbnails.
- The interface itself is black, white and gray: no blue or other accent color. Selection is marked with a ring or an inverted row, not a colored fill. Switches are the exception: they use the system green, so on and off are easy to tell apart.
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
