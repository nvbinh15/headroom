#!/usr/bin/env bash
# Build an unsigned (ad-hoc signed) Headroom.dmg for distribution.
#
# Output: build/Headroom.dmg
# Tools:  xcodegen, create-dmg  (brew install both)
#
# Note: the resulting .app is ad-hoc signed, so first-launch will require
# right-click → Open under Gatekeeper. The widget extension will not be
# usable until the build is signed with a real Developer ID.

set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Headroom"
SCHEME="HeadroomApp"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"

require() {
  command -v "$1" >/dev/null 2>&1 || {
    printf '✗ %s not installed. Run: brew install %s\n' "$1" "$1" >&2
    exit 1
  }
}
require xcodegen
require create-dmg

echo "→ Generating Xcode project"
xcodegen generate --quiet

echo "→ Cleaning $BUILD_DIR/"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "→ Archiving (Release, ad-hoc signed)"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  clean archive

echo "→ Extracting .app from archive"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$APP_PATH"

echo "→ Building DMG"
rm -f "$DMG_PATH"
create-dmg \
  --volname "$APP_NAME" \
  --window-pos 200 120 \
  --window-size 540 360 \
  --icon-size 100 \
  --icon "$APP_NAME.app" 140 180 \
  --hide-extension "$APP_NAME.app" \
  --app-drop-link 400 180 \
  --no-internet-enable \
  "$DMG_PATH" \
  "$APP_PATH"

echo
echo "✓ Built $DMG_PATH"
ls -lh "$DMG_PATH"
echo
echo "Next: tag a release and upload"
echo "  git tag v\$VERSION && git push --tags"
echo "  gh release create v\$VERSION '$DMG_PATH' --title 'Headroom v\$VERSION' --notes-file CHANGELOG.md"
