# Releasing Proof

Releases are signed with the owner's Developer ID, notarized by Apple and published as GitHub releases with a `.dmg` attached. `scripts/release.sh` builds, signs, notarizes and packages a release; publishing it is one `gh` command. See decision 0038 for why signing lives in the script and not in the Xcode project.

## One-time setup on the Mac that makes releases

1. **Developer ID certificate.** In Xcode, open Settings › Accounts, select the Apple ID of the Developer Program membership, choose Manage Certificates, click + and choose Developer ID Application. The certificate and its private key go into the login keychain. Check that it's there:

   ```bash
   security find-identity -v -p codesigning
   ```

   One line should start with `Developer ID Application:`.

2. **Notary credentials.** Create an app-specific password at account.apple.com (Sign-In and Security › App-Specific Passwords), then save it in the Keychain under the profile name the script uses:

   ```bash
   xcrun notarytool store-credentials proof-notary --apple-id <your Apple ID> --team-id <team ID>
   ```

   `notarytool` asks for the app-specific password and stores it in the login keychain. The team ID is the 10 characters in parentheses at the end of the certificate's name. The credentials never go in the repository. To use another profile name, set `NOTARY_PROFILE` when running the script.

## Making a release

1. On an up-to-date `main` with no uncommitted changes, set the version in `App/Version.xcconfig`: raise `MARKETING_VERSION` for each release, and `CURRENT_PROJECT_VERSION` for every build sent to Apple. Merge that change through a pull request like any other.
2. Build, sign, notarize and package:

   ```bash
   scripts/release.sh
   ```

   It takes a few minutes, most of it waiting for Apple's notary service, which runs twice: once for the app and once for the disk image. The result is `build/release/Proof-<version>.dmg`. If notarization fails, the script stops and prints the submission ID; `xcrun notarytool log <id> --keychain-profile proof-notary` shows why.
3. Open the `.dmg` on a second Mac or a fresh user account, drag Proof to Applications, open it, and open a folder of photos. It should open without a Gatekeeper warning.
4. Publish that same `.dmg` as a GitHub release, tagged `v<version>` at the commit it was built from:

   ```bash
   gh release create v0.1 build/release/Proof-0.1.dmg --target main --title "Proof 0.1" --notes "Requires macOS 27 on an Apple silicon Mac. See Install in the README."
   ```

   Replace both `0.1`s with the version. The release page is public, and its download link is the one the README's Install section points to.
