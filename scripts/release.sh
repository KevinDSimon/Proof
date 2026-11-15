#!/bin/zsh
# Builds a Proof release others can install: archives the Release build,
# signs it with the owner's Developer ID, notarizes and staples it, and
# packages it as a .dmg in build/release. Publishing the tested .dmg as a
# GitHub release is a separate step (docs/releasing.md).
#
# Needs, once per Mac (see docs/releasing.md):
#   - a "Developer ID Application" certificate in the login keychain
#   - notary credentials saved with `xcrun notarytool store-credentials`
#     under the profile name in NOTARY_PROFILE (default: proof-notary)
#
# Usage: scripts/release.sh

set -euo pipefail

if (( $# > 0 )); then
  echo "Usage: scripts/release.sh" >&2
  exit 64
fi

root=${0:A:h:h}
cd "$root"

notary_profile=${NOTARY_PROFILE:-proof-notary}
version=$(sed -n 's/^MARKETING_VERSION *= *//p' App/Version.xcconfig)
build=$(sed -n 's/^CURRENT_PROJECT_VERSION *= *//p' App/Version.xcconfig)
out=build/release
archive=$out/Proof.xcarchive
app=$out/export/Proof.app
dmg=$out/Proof-$version.dmg

fail() { echo "error: $*" >&2; exit 1; }
step() { echo "\n==> $*"; }

step "Checking prerequisites for Proof $version ($build)"

[[ -n "$version" && -n "$build" ]] || fail "App/Version.xcconfig has no MARKETING_VERSION or CURRENT_PROJECT_VERSION."

if [[ -n "$(git status --porcelain)" ]]; then
  fail "The working tree has uncommitted changes. Release from a clean checkout of main."
fi

identity=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)
[[ -n "$identity" ]] || fail "No \"Developer ID Application\" certificate in the keychain. See docs/releasing.md."
team=$(echo "$identity" | sed -n 's/.*(\([A-Z0-9]*\))$/\1/p')
echo "Signing as: $identity"

xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null 2>&1 \
  || fail "No notary credentials under the keychain profile \"$notary_profile\". See docs/releasing.md."

rm -rf "$out"
mkdir -p "$out"

# The Xcode project keeps signing ad hoc so anyone can build it without a
# developer team; only this script signs with the Developer ID.
step "Archiving the Release build"
xcodebuild archive \
  -project App/Proof.xcodeproj \
  -scheme Proof \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Developer ID Application" \
  DEVELOPMENT_TEAM="$team" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  | grep -E '^(\*\*|error:|warning: .*sign)' || true
[[ -d "$archive" ]] || fail "The archive failed. Run the xcodebuild command above without the filter to see why."

step "Exporting for Developer ID distribution"
cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Developer ID Application</string>
	<key>teamID</key>
	<string>$team</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" \
  | grep -E '^(\*\*|error:)' || true
[[ -d "$app" ]] || fail "The export failed."

codesign --verify --deep --strict "$app"
codesign --display --verbose=2 "$app" 2>&1 | grep -q 'flags=.*runtime' \
  || fail "The exported app isn't signed with the hardened runtime."

# The app is notarized and stapled on its own first, so it still opens
# offline after it's dragged out of the disk image.
step "Notarizing the app"
ditto -c -k --keepParent "$app" "$out/Proof.zip"
xcrun notarytool submit "$out/Proof.zip" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$app"
rm "$out/Proof.zip"

step "Packaging $dmg"
staging=$out/dmg
mkdir -p "$staging"
ditto "$app" "$staging/Proof.app"
ln -s /Applications "$staging/Applications"
diskutil image create from --format UDZO --volumeName "Proof $version" "$staging" "$dmg" >/dev/null
rm -rf "$staging"
codesign --sign "$identity" --timestamp "$dmg"

step "Notarizing the disk image"
xcrun notarytool submit "$dmg" --keychain-profile "$notary_profile" --wait
xcrun stapler staple "$dmg"

step "Checking Gatekeeper accepts both"
spctl --assess --type execute --verbose "$app"
spctl --assess --type open --context context:primary-signature --verbose "$dmg"

step "Done: $dmg"
