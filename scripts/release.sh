#!/usr/bin/env bash
# Builds, signs, notarizes and publishes Copycat to GitHub Releases.
# Usage: DEVELOPMENT_TEAM=XXXXXXXXXX scripts/release.sh 1.0.0
# Needs: "Developer ID Application" and "Developer ID Installer" certificates in the keychain, and asc (App Store Connect CLI) signed in
#   with an API key (`asc auth status`).
set -euo pipefail

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh <major.minor.patch>" >&2; exit 2; }
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID}"
REPO="plosson/copycat"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
cd "$ROOT"

git diff --quiet && git diff --cached --quiet || { echo "working tree is not clean" >&2; exit 1; }
if gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
  echo "release v$VERSION already exists" >&2; exit 1
fi

rm -rf "$BUILD"
mkdir -p "$BUILD"

swift test --package-path CopycatCore
xcodegen generate

xcodebuild archive \
  -project Copycat.xcodeproj -scheme Copycat -configuration Release \
  -archivePath "$BUILD/Copycat.xcarchive" \
  MARKETING_VERSION="$VERSION" DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"

cat > "$BUILD/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$DEVELOPMENT_TEAM</string>
  <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive \
  -archivePath "$BUILD/Copycat.xcarchive" \
  -exportOptionsPlist "$BUILD/ExportOptions.plist" \
  -exportPath "$BUILD/export"
APP="$BUILD/export/Copycat.app"

# Notarizes a zip, dmg or pkg. asc exits 0 whatever Apple decides, so ask for the final status
# and stop unless it is Accepted.
notarize() {
  local id status
  id="$(asc notarization submit --file "$1" --wait | jq -r '.data.id // .id')"
  status="$(asc notarization status --id "$id" | jq -r '.data.attributes.status')"
  echo "Notarization of $(basename "$1") ($id): $status"
  if [[ "$status" != "Accepted" ]]; then
    asc notarization log --id "$id" >&2 || true
    echo "notarization was not accepted" >&2; exit 1
  fi
}

ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
notarize "$BUILD/notarize.zip"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

ZIP="$BUILD/Copycat-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"

# Installer that always puts the app in /Applications: not relocatable, so it never
# overwrites another copy of Copycat found elsewhere on the disk.
PKG="$BUILD/Copycat-$VERSION.pkg"
INSTALLER_ID="$(security find-identity -v | awk -v team="($DEVELOPMENT_TEAM)\"" '/Developer ID Installer/ && index($0, team) { print $2; exit }')"
[[ -n "$INSTALLER_ID" ]] || { echo "no Developer ID Installer certificate for team $DEVELOPMENT_TEAM" >&2; exit 1; }
rm -rf "$BUILD/pkgroot"
mkdir -p "$BUILD/pkgroot"
ditto "$APP" "$BUILD/pkgroot/Copycat.app"
pkgbuild --analyze --root "$BUILD/pkgroot" "$BUILD/component.plist"
plutil -replace 0.BundleIsRelocatable -bool NO "$BUILD/component.plist"
pkgbuild --root "$BUILD/pkgroot" --component-plist "$BUILD/component.plist" \
  --identifier com.plosson.copycat.pkg --version "$VERSION" --install-location /Applications \
  --sign "$INSTALLER_ID" "$PKG"
notarize "$PKG"
xcrun stapler staple "$PKG"
spctl --assess --type install --verbose "$PKG"

gh release create "v$VERSION" "$ZIP" "$PKG" --repo "$REPO" --title "Copycat $VERSION" \
  --notes "Open Copycat-$VERSION.pkg to install Copycat in Applications. Or download Copycat-$VERSION.zip, unzip, move Copycat.app to Applications and open it."
echo "Published v$VERSION"
