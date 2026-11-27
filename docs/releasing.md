# Releasing Proof

The Mac app and the iPad and iPhone app are released separately. The Mac app is a `.dmg` on GitHub; the iOS app goes to testers through TestFlight.

## The Mac app

Releases are signed with the owner's Developer ID, notarized by Apple and published as GitHub releases with a `.dmg` attached. `scripts/release.sh` builds, signs, notarizes and packages a release; publishing it is one `gh` command. See decision 0038 for why signing lives in the script and not in the Xcode project.

### One-time setup on the Mac that makes releases

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

### Making a release

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

## The iPad and iPhone app

Builds are signed for App Store distribution with the owner's team, KEVIN DOUGLAS SIMON (`XQV2DS499B`), and uploaded to App Store Connect, where TestFlight sends them to testers. The bundle identifier is `com.kevinsimon.proof`, the same as the Mac app's. `scripts/testflight.sh` archives, signs and uploads; adding testers is done in App Store Connect. See decision 0058 for why signing lives in the script.

### One-time setup

These steps use the owner's Apple Developer account, so only the owner can do them.

1. **Sign Xcode in.** In Xcode, open Settings › Accounts and check that the Apple ID of the Developer Program membership is listed, with the team KEVIN DOUGLAS SIMON. The script uses this account to create the signing certificate and provisioning profile and to upload builds, so nothing is stored in the repository.
2. **Create the app in App Store Connect.** At appstoreconnect.apple.com, open Apps, click + and choose New App. Choose iOS, name it Proof, pick the primary language, and choose the bundle identifier `com.kevinsimon.proof`. If it isn't in the list, register it first at developer.apple.com under Certificates, Identifiers & Profiles › Identifiers (an App ID with no extra capabilities), then reload the form. The SKU is any text only the owner sees, such as `proof`. Choose Full Access for user access.
3. **Add testers.** In the app's TestFlight tab:
   - **Internal testers** are people on the developer team in App Store Connect, such as the owner. Create an internal group, add yourself, and turn on automatic distribution so every processed build reaches the group without review.
   - **External testers** are anyone with an email address. Create an external group and add their emails, or turn on a public link. The first build sent to an external group goes through Apple's beta review, which usually takes a day; later builds of the same version usually don't.
4. **Install TestFlight** from the App Store on each iPad and iPhone that will run the app, signed in with the tester's Apple Account.

### Sending a build to TestFlight

1. On an up-to-date `main` with no uncommitted changes, raise `CURRENT_PROJECT_VERSION` in `App/Version.xcconfig` (and `MARKETING_VERSION` for a new version), and merge that change through a pull request. App Store Connect refuses a build number it has already received for the same version. The Mac and iOS apps share these numbers.
2. Archive, sign and upload:

   ```bash
   scripts/testflight.sh
   ```

   The first run may ask for the login keychain password so Xcode can store the new Apple Distribution certificate. The archive is kept in `build/testflight/ProofiOS.xcarchive`. If the upload fails, `build/testflight/upload.log` says why.
3. After a few minutes App Store Connect finishes processing the build and emails the owner. It then shows in the app's TestFlight tab. Internal groups with automatic distribution get it right away; for an external group, add the build to the group and fill in What to Test.
4. On the iPad or iPhone, open TestFlight, choose Proof and tap Install. Open a folder of photos from Files and edit one to check the build.

The app declares that it uses no encryption beyond what iOS provides (`ITSAppUsesNonExemptEncryption` is `NO`), so App Store Connect doesn't ask about export compliance for each build.
