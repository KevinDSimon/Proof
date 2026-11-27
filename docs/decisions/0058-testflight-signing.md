# 0058. iOS builds are signed for TestFlight in a script

Date: 2026-11-27
Status: Accepted

## Context
Issue #238. The iPad and iPhone app runs only in the simulator: the Xcode project signs it ad hoc, as it does the Mac app (decision 0038), so anyone can build it and CI needs no certificate. To install it on devices and share it with testers, a build has to be signed for App Store distribution and uploaded to App Store Connect, where TestFlight delivers it.

## Decision
- The owner's individual team, KEVIN DOUGLAS SIMON (`XQV2DS499B`), signs the iOS app. It is the team that signs the Mac release.
- The iOS app keeps the bundle identifier `com.kevinsimon.proof`, the same as the Mac app's, so the two can share one purchase if the Mac app is ever on the App Store. The app has no extensions or app groups, so it needs no other identifiers.
- The Xcode project keeps signing ad hoc. `scripts/testflight.sh` passes the team and automatic signing to `xcodebuild archive`, then exports with the `app-store-connect` method and the `upload` destination. Xcode creates the Apple Distribution certificate and the provisioning profile with `-allowProvisioningUpdates`, using the Apple account signed in to Xcode, so no credentials are stored in the repository or the script.
- The version and build number come from `App/Version.xcconfig`, shared with the Mac app. The export doesn't let Xcode change them.
- The iOS Info.plist sets `ITSAppUsesNonExemptEncryption` to `NO`. Proof uses no encryption beyond what iOS provides, so App Store Connect doesn't ask about export compliance for every build.
- Creating the app in App Store Connect, the signing certificates, uploading and managing testers need the owner's Apple account and are the owner's steps, described in `docs/releasing.md`.

## Consequences
- Builds from Xcode and CI are unchanged. Only a Mac signed in to the owner's account can send a build to TestFlight.
- Running Proof on a device from Xcode for debugging still needs the team chosen in Xcode's Signing & Capabilities for that run, without committing it.
- Uploading from GitHub Actions would need an App Store Connect API key as a repository secret. That is left for a later issue.
