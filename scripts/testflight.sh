#!/bin/zsh
# Builds the iPad and iPhone app for TestFlight: archives the Release build,
# signs it for App Store distribution with the owner's team, and uploads it
# to App Store Connect. Adding testers is done in App Store Connect
# (docs/releasing.md).
#
# Needs, once per Mac (see docs/releasing.md):
#   - Xcode signed in to the owner's Apple Developer account
#   - the app created in App Store Connect with the bundle identifier
#     com.kevinsimon.proof
#
# Xcode creates the Apple Distribution certificate and the provisioning
# profile the first time, through -allowProvisioningUpdates.
#
# Usage: scripts/testflight.sh

set -euo pipefail

if (( $# > 0 )); then
  echo "Usage: scripts/testflight.sh" >&2
  exit 64
fi

root=${0:A:h:h}
cd "$root"

team=${TEAM_ID:-XQV2DS499B}
version=$(sed -n 's/^MARKETING_VERSION *= *//p' App/Version.xcconfig)
build=$(sed -n 's/^CURRENT_PROJECT_VERSION *= *//p' App/Version.xcconfig)
out=build/testflight
archive=$out/ProofiOS.xcarchive

fail() { echo "error: $*" >&2; exit 1; }
step() { echo "\n==> $*"; }

step "Checking prerequisites for Proof for iOS $version ($build)"

[[ -n "$version" && -n "$build" ]] || fail "App/Version.xcconfig has no MARKETING_VERSION or CURRENT_PROJECT_VERSION."

if [[ -n "$(git status --porcelain)" ]]; then
  fail "The working tree has uncommitted changes. Build from a clean checkout of main."
fi

rm -rf "$out"
mkdir -p "$out"

# The Xcode project keeps signing ad hoc so anyone can build it without a
# developer team; only this script signs for App Store Connect.
step "Archiving the Release build"
xcodebuild archive \
  -project App/Proof.xcodeproj \
  -scheme ProofiOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$archive" \
  -allowProvisioningUpdates \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGN_IDENTITY="Apple Development" \
  DEVELOPMENT_TEAM="$team" \
  | grep -E '^(\*\*|error:|warning: .*sign)' || true
[[ -d "$archive" ]] || fail "The archive failed. Run the xcodebuild command above without the filter to see why."

# The build number comes from App/Version.xcconfig, so Xcode isn't allowed to
# change it. App Store Connect refuses a build number it has already seen.
step "Uploading to App Store Connect"
cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>signingStyle</key>
	<string>automatic</string>
	<key>teamID</key>
	<string>$team</string>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
	<key>uploadSymbols</key>
	<true/>
</dict>
</plist>
EOF
upload_log=$out/upload.log
xcodebuild -exportArchive \
  -archivePath "$archive" \
  -exportPath "$out/export" \
  -exportOptionsPlist "$out/ExportOptions.plist" \
  -allowProvisioningUpdates \
  > "$upload_log" 2>&1 \
  || { grep -E 'error' "$upload_log" >&2 || true; fail "The upload failed. $upload_log has the whole output."; }

step "Uploaded Proof $version ($build). App Store Connect processes it for a few minutes before it appears in TestFlight."
