#!/usr/bin/env bash
# Builds, signs, notarizes and publishes Copycat to GitHub Releases (pkg, zip and Sparkle appcast), then updates
# its Homebrew cask. The steps live in the houlahop-mac-release submodule: see scripts/mac-release/lib.sh for
# what they need.
# Usage: DEVELOPMENT_TEAM=XXXXXXXXXX scripts/release.sh 1.0.0
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
[[ -f scripts/mac-release/lib.sh ]] || git submodule update --init scripts/mac-release
source scripts/mac-release/lib.sh

release_version "${1:-}"
: "${DEVELOPMENT_TEAM:?set DEVELOPMENT_TEAM to your Apple team ID}"
TEAM="$DEVELOPMENT_TEAM"
NAME="Copycat"
FILE_NAME="Copycat-$VERSION"
REPO="plosson/copycat"
BUNDLE_ID="com.plosson.copycat"
PROJECT="$ROOT/Copycat.xcodeproj"
SCHEME="Copycat"
BUILD="$ROOT/build/release"
SPARKLE_ACCOUNT="copycat"
CASK="copycat"
CASK_DESC="Lets web pages copy real files, like animated GIFs and videos, to the clipboard"
MIN_MACOS="sonoma"

release_check_clean
release_clean_build

swift test --package-path CopycatCore
xcodegen generate

release_archive
release_export
release_notarize_app
release_pkg
release_appcast
release_publish
release_cask
