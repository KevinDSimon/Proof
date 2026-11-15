# 0038. Developer ID signing happens in the release script

Date: 2026-11-15
Status: Accepted

## Context
Issue #25 asks for a build others can download and open without a Gatekeeper warning, which needs a Developer ID Application certificate, the hardened runtime and notarization. The Xcode project signs ad hoc in both configurations, so anyone can build and run Proof without an Apple developer team, and CI builds it the same way.

## Decision
- The Xcode project keeps signing ad hoc. `scripts/release.sh` passes the Developer ID identity and the owner's team to `xcodebuild archive` as build settings, then exports the archive with the `developer-id` method.
- The script notarizes and staples the app first, so it opens offline after it's dragged to Applications, then packages it as a `.dmg` with an Applications shortcut, signs, notarizes and staples the disk image, and checks both with `spctl`.
- Notary credentials are a `notarytool` Keychain profile (`proof-notary` by default), never in the repository or in environment files.
- The version and build number live in `App/Version.xcconfig`, which both of the app target's configurations use. About Proof shows them through the standard About panel.
- The script refuses to run with uncommitted changes. It doesn't publish: the owner tests the `.dmg` it made, then attaches that same file to a GitHub release `v<version>` with `gh release create`.

## Consequences
- Builds from Xcode and CI are unchanged and need no certificate. Only a Mac with the certificate and the Keychain profile can make a release.
- A build signed with Debug settings never reaches testers; every release is a fresh Release archive.
- Running releases from GitHub Actions would need the certificate and notary credentials as repository secrets. That is left for a later issue.
