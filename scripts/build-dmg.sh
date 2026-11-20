#!/usr/bin/env bash
# Build a signed Headroom.dmg.
#
# Output: build/Headroom.dmg
# Tools:  xcodegen, create-dmg  (brew install both)
#
# Signing: uses $SIGN_IDENTITY if set, else the first "Developer ID Application"
# or "Apple Development" certificate in your keychain, else ad-hoc ("-").
# A real certificate keeps the code signature stable across builds, so macOS
# remembers "Always Allow" keychain approvals after updates. Gatekeeper still
# warns on other Macs unless the build is Developer ID signed and notarized.

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

pick_identity() {
  security find-identity -v -p codesigning | grep -oE "\"$1: [^\"]+\"" | head -1 | tr -d '"' || true
}
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  SIGN_IDENTITY=$(pick_identity "Developer ID Application")
  [[ -n "$SIGN_IDENTITY" ]] || SIGN_IDENTITY=$(pick_identity "Apple Development")
  SIGN_IDENTITY=${SIGN_IDENTITY:--}
fi
TEAM_ID=""
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  TEAM_ID=$(security find-certificate -c "$SIGN_IDENTITY" -p | openssl x509 -noout -subject \
    | grep -oE 'OU ?= ?[A-Z0-9]{10}' | grep -oE '[A-Z0-9]{10}$' || true)
fi
# Notarization requires the hardened runtime; only Developer ID builds get notarized.
HARDENED=NO
[[ "$SIGN_IDENTITY" == "Developer ID Application"* ]] && HARDENED=YES

echo "→ Generating Xcode project"
xcodegen generate --quiet

echo "→ Cleaning $BUILD_DIR/"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "→ Archiving (Release, signed with: $SIGN_IDENTITY${TEAM_ID:+ / team $TEAM_ID})"
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ENABLE_HARDENED_RUNTIME="$HARDENED" \
  clean archive

echo "→ Extracting .app from archive"
cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

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
