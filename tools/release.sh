#!/usr/bin/env bash
#
# Build a distributable Rounds.app, package it as a DMG, and emit the appcast.json the
# in-app update banner reads. Signing/notarization is the one manual step (needs your
# Apple Developer ID) — see NOTARIZE below; without it the DMG still installs with a
# Gatekeeper prompt, which is fine for testing and side-loading.
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/release"
DIST="$ROOT/dist"
SCHEME="rounds"

VERSION="$(/usr/bin/sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' "$ROOT/rounds.xcodeproj/project.pbxproj" | head -1)"
REPO="${ROUNDS_REPO:-https://github.com/rounds-app/rounds}"
echo "==> Building Rounds $VERSION (Release)"

rm -rf "$DERIVED"
mkdir -p "$DIST"

# Ad-hoc sign for a self-contained local build. For a real release, drop the override and
# let automatic signing use your Developer ID Application certificate.
xcodebuild -project "$ROOT/rounds.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=NO \
  build >/dev/null

APP="$DERIVED/Build/Products/Release/$SCHEME.app"
[ -d "$APP" ] || { echo "build produced no app"; exit 1; }

echo "==> Packaging DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Rounds.app"
ln -s /Applications "$STAGE/Applications"
DMG="$DIST/Rounds-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Rounds $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"
SIZE="$(stat -f%z "$DMG")"

echo "==> Writing appcast.json"
cat > "$DIST/appcast.json" <<JSON
{
  "latestVersion": "$VERSION",
  "minSupported": "1.0.0",
  "downloadURL": "$REPO/releases/download/v$VERSION/Rounds-$VERSION.dmg",
  "sizeBytes": $SIZE,
  "notes": "Warm streaming chat, trust-ranked sources panel, privacy-first analytics, and the update banner."
}
JSON

echo ""
echo "Done:"
echo "  $DMG  ($(printf '%.1f' "$(echo "$SIZE/1048576" | bc -l)") MB)"
echo "  $DIST/appcast.json"
echo ""
echo "NOTARIZE (manual, one time, for public distribution):"
echo "  1) Build with your 'Developer ID Application' cert (remove the CODE_SIGN_IDENTITY override)."
echo "  2) xcrun notarytool submit \"$DMG\" --apple-id <you> --team-id N73W6XQW8H --password <app-pw> --wait"
echo "  3) xcrun stapler staple \"$DMG\""
echo "  4) Upload the DMG to the v$VERSION GitHub release and commit dist/appcast.json to main"
echo "     (UpdateService.manifestURL points at raw .../main/appcast.json)."
