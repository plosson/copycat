#!/usr/bin/env bash
# Builds, signs, notarizes and publishes Copycat to GitHub Releases.
# Usage: DEVELOPMENT_TEAM=XXXXXXXXXX scripts/release.sh 1.0.0
# Needs: a "Developer ID Application" certificate in the keychain, and a notarytool profile created once with
#   xcrun notarytool store-credentials copycat-notary --apple-id <id> --team-id <team>
set -euo pipefail

VERSION="${1:-}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: scripts/release.sh <major.minor.patch>" >&2; exit 2; }
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID}"
NOTARY_PROFILE="${NOTARY_PROFILE:-copycat-notary}"
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

ditto -c -k --keepParent "$APP" "$BUILD/notarize.zip"
xcrun notarytool submit "$BUILD/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

ZIP="$BUILD/Copycat-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Copycat $VERSION" \
  --notes "Download Copycat-$VERSION.zip, unzip, move Copycat.app to Applications and open it."
echo "Published v$VERSION"
