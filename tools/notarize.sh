#!/usr/bin/env bash
#
# Build a Rounds.app signed with your Developer ID, notarize it with Apple, staple the
# ticket, and package a Gatekeeper-clean DMG. This is the ONE step that removes the scary
# "Apple could not verify this app is free of malware" screen for downloaders.
#
# WHY this exists: a Developer-ID-signed + notarized build launches with at most a normal
# "downloaded from the internet" confirmation. An ad-hoc / Apple-Development build (what
# tools/release.sh makes) is REJECTED by Gatekeeper, and on macOS 15+ the old
# right-click -> Open bypass is gone — users must dig into System Settings to run it.
#
# ── ONE-TIME SETUP (do these once, they need YOUR Apple account) ───────────────────────
#
#   1. Create a "Developer ID Application" certificate (the team already has an Apple
#      Distribution cert, but that is App-Store-only and will NOT work here):
#         Xcode -> Settings -> Accounts -> select the LP STABLE TECH INC team
#         -> Manage Certificates -> "+" -> Developer ID Application
#      (Only the team's Account Holder/Admin can create it.) Confirm it landed:
#         security find-identity -v -p codesigning | grep "Developer ID Application"
#
#   2. Store notarization credentials in the keychain once (so this script runs unattended).
#      Make an app-specific password at appleid.apple.com -> Sign-In and Security
#      -> App-Specific Passwords, then:
#         xcrun notarytool store-credentials "rounds-notary" \
#             --apple-id "you@example.com" \
#             --team-id "N73W6XQW8H" \
#             --password "xxxx-xxxx-xxxx-xxxx"
#
# ── RUN ────────────────────────────────────────────────────────────────────────────────
#
#         ./tools/notarize.sh
#
#   Override the defaults with env vars if needed:
#         DEV_ID_APP="Developer ID Application: LP STABLE TECH INC. (N73W6XQW8H)" \
#         NOTARY_PROFILE="rounds-notary" ./tools/notarize.sh
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED="$ROOT/build/notarize"
DIST="$ROOT/dist"
SCHEME="rounds"
TEAM_ID="N73W6XQW8H"
NOTARY_PROFILE="${NOTARY_PROFILE:-rounds-notary}"

VERSION="$(/usr/bin/sed -n 's/.*MARKETING_VERSION = \([0-9.]*\);.*/\1/p' "$ROOT/rounds.xcodeproj/project.pbxproj" | head -1)"

# ── Preflight: Developer ID cert ────────────────────────────────────────────────────────
if [ -z "${DEV_ID_APP:-}" ]; then
  DEV_ID_APP="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)"
fi
if [ -z "$DEV_ID_APP" ]; then
  cat >&2 <<'ERR'
✗ No "Developer ID Application" certificate found in your keychain.

  You have an "Apple Distribution" cert, but that is for the App Store only and cannot
  notarize a directly-distributed app. Create the Developer ID one first:

    Xcode -> Settings -> Accounts -> (LP STABLE TECH INC team) -> Manage Certificates
      -> "+" -> Developer ID Application

  Then re-run this script. See the ONE-TIME SETUP comment at the top for details.
ERR
  exit 1
fi
echo "==> Signing identity: $DEV_ID_APP"

# ── Preflight: notarytool credentials ───────────────────────────────────────────────────
if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  cat >&2 <<ERR
✗ notarytool keychain profile "$NOTARY_PROFILE" is not set up (or its credentials are bad).

  Create it once with an app-specific password from appleid.apple.com:

    xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
        --apple-id "you@example.com" --team-id "$TEAM_ID" --password "xxxx-xxxx-xxxx-xxxx"

ERR
  exit 1
fi

# Submit a file to the notary service and wait. `notarytool submit --wait` exits 0 even when
# the verdict is "Invalid", so we parse the status ourselves: on anything but Accepted, print
# Apple's detailed per-issue log and abort (don't proceed to a doomed staple).
notarize_or_die() {
  local f="$1" out sid
  out="$(xcrun notarytool submit "$f" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1)"
  echo "$out"
  sid="$(awk '/^[[:space:]]*id:/{print $2; exit}' <<<"$out")"
  if ! grep -q "status: Accepted" <<<"$out"; then
    echo "" >&2
    echo "✗ Notarization FAILED for $(basename "$f") (verdict not Accepted). Apple's log:" >&2
    [ -n "$sid" ] && xcrun notarytool log "$sid" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
  fi
}

mkdir -p "$DIST"
rm -rf "$DERIVED"

# ── Build, signed with Developer ID + hardened runtime (already enabled in the project) ──
echo "==> Building Rounds $VERSION (Release, Developer ID)"
# -destination 'generic/platform=macOS' builds a UNIVERSAL binary (arm64 + x86_64) so the app
# runs on both Apple Silicon and Intel Macs, not just the build machine's architecture.
xcodebuild -project "$ROOT/rounds.xcodeproj" -scheme "$SCHEME" -configuration Release \
  -derivedDataPath "$DERIVED" \
  -destination 'generic/platform=macOS' \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$DEV_ID_APP" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  build >/dev/null

APP="$DERIVED/Build/Products/Release/$SCHEME.app"
[ -d "$APP" ] || { echo "✗ build produced no app" >&2; exit 1; }

# Re-sign Sparkle's nested helpers with our Developer ID + hardened runtime + secure timestamp.
# xcodebuild signs the main app and Sparkle.framework's top binary, but NOT the deeply nested
# Updater.app / Autoupdate / XPCServices — they keep Sparkle's own signature and have no secure
# timestamp, which Apple's notary rejects. Sign inside-out, then re-seal the framework and app.
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
  echo "==> Re-signing Sparkle helpers (Developer ID + hardened runtime + timestamp)"
  SPV="$APP/Contents/Frameworks/Sparkle.framework/Versions/Current"
  for item in \
    "$SPV/XPCServices/Downloader.xpc" \
    "$SPV/XPCServices/Installer.xpc" \
    "$SPV/Updater.app" \
    "$SPV/Autoupdate" \
    "$APP/Contents/Frameworks/Sparkle.framework" \
    "$APP" ; do
    codesign --force --options runtime --timestamp --sign "$DEV_ID_APP" "$item"
  done
fi

# Verify the signature is Developer ID + hardened runtime before we spend a notarization.
# Capture codesign output to a var first: `codesign | grep -q` under `set -o pipefail`
# fails spuriously because grep -q closes the pipe on first match and codesign dies on SIGPIPE.
echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP"
SIGINFO="$(codesign -dvv "$APP" 2>&1)"
grep -q "Authority=Developer ID Application" <<<"$SIGINFO" \
  || { echo "✗ app is not Developer-ID-signed (got something else) — aborting" >&2; exit 1; }
grep -q "(runtime)" <<<"$SIGINFO" \
  || { echo "✗ hardened runtime missing — aborting" >&2; exit 1; }

# com.apple.security.get-task-allow is a debug-only entitlement; if it's present Apple rejects
# notarization ("Archive contains critical validation errors"). Catch it locally — before we
# spend a notarization round-trip — instead of finding out from the notary service.
ENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
if grep -q "get-task-allow" <<<"$ENTS"; then
  echo "✗ app still carries com.apple.security.get-task-allow — notarization would be rejected." >&2
  echo "  (CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO should strip it; check the project's Release entitlements.)" >&2
  exit 1
fi

# ── Notarize the app, then staple (so it validates offline too) ─────────────────────────
echo "==> Notarizing app (this uploads to Apple and waits; usually 1-5 min)"
ZIP="$DERIVED/Rounds-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIP"
notarize_or_die "$ZIP"
echo "==> Stapling app"
xcrun stapler staple "$APP"

# ── Package the stapled app into a STYLED DMG (background + arrow + positioned icons) ─────
echo "==> Packaging DMG (styled: drag-to-Applications layout)"
VOL="Rounds $VERSION"
DMG="$DIST/Rounds-$VERSION.dmg"
RW="$DERIVED/rw.dmg"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/Rounds.app"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
swift "$ROOT/tools/dmg-background.swift" "$STAGE/.background/background.png"
rm -f "$DMG" "$RW"
# A writable image we can style in Finder, then compress to a read-only UDZO for distribution.
hdiutil create -quiet -volname "$VOL" -srcfolder "$STAGE" -fs HFS+ -format UDRW -ov "$RW"
hdiutil attach -readwrite -noverify -noautoopen "$RW" -quiet
osascript <<OSA || echo "  (Finder styling failed — shipping the plain layout instead)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 740, 500}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set background picture of opts to file ".background:background.png"
    set position of item "Rounds.app" of container window to {135, 190}
    set position of item "Applications" of container window to {405, 190}
    update without registering applications
    delay 1
    close
  end tell
end tell
OSA
sync
hdiutil detach "/Volumes/$VOL" -quiet || true
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
rm -f "$RW"
rm -rf "$STAGE"

echo "==> Notarizing DMG"
notarize_or_die "$DMG"
xcrun stapler staple "$DMG"

# ── Sparkle update archive + signed appcast.xml (one-click auto-update) ──────────────────
# Sparkle downloads a ZIP of the stapled app and verifies its EdDSA signature against the
# SUPublicEDKey in Info.plist. generate_appcast signs with the private key in your login
# keychain (created once via Sparkle's generate_keys) and writes appcast.xml. Sparkle compares
# versions by CFBundleVersion (CURRENT_PROJECT_VERSION) — keep it monotonic across releases.
echo "==> Building Sparkle update archive + appcast.xml"
SPARKLE_GA="$(find "$HOME/Library/Developer/Xcode/DerivedData" -type f -name generate_appcast -path '*sparkle*' 2>/dev/null | head -1)"
if [ -z "$SPARKLE_GA" ]; then
  echo "✗ generate_appcast not found — run 'xcodebuild -resolvePackageDependencies' first." >&2
  exit 1
fi
APPCAST_STAGE="$DERIVED/appcast-stage"
rm -rf "$APPCAST_STAGE"; mkdir -p "$APPCAST_STAGE"
ZIPDIST="$APPCAST_STAGE/Rounds-$VERSION.zip"
/usr/bin/ditto -c -k --keepParent "$APP" "$ZIPDIST"   # zip of the notarized + stapled app
# Optional human release notes shown in Sparkle's dialog (set RELEASE_NOTES_HTML to a file).
if [ -n "${RELEASE_NOTES_HTML:-}" ] && [ -f "$RELEASE_NOTES_HTML" ]; then
  cp "$RELEASE_NOTES_HTML" "$APPCAST_STAGE/Rounds-$VERSION.html"
fi
"$SPARKLE_GA" \
  --download-url-prefix "https://github.com/Rounds-Org/rounds/releases/download/v$VERSION/" \
  "$APPCAST_STAGE"
cp "$APPCAST_STAGE/appcast.xml" "$ROOT/appcast.xml"   # served raw from main; SUFeedURL points here
cp "$ZIPDIST" "$DIST/Rounds-$VERSION.zip"

# ── Final verification: this is what a downloader's Gatekeeper will see ──────────────────
echo "==> Gatekeeper verdict (must say 'accepted')"
spctl -a -vvv -t exec "$APP" 2>&1 || true
xcrun stapler validate "$DMG" 2>&1 | tail -1
SIZE="$(stat -f%z "$DMG")"

echo ""
echo "✓ Done — notarized, stapled, Gatekeeper-clean, with a Sparkle appcast:"
echo "    $DMG  ($(printf '%.1f' "$(echo "$SIZE/1048576" | bc -l)") MB)   ← website download"
echo "    $DIST/Rounds-$VERSION.zip   ← Sparkle auto-update archive"
echo "    $ROOT/appcast.xml           ← commit this; SUFeedURL points at raw main"
echo ""
echo "Next (manual): create the release and upload BOTH assets, then commit appcast.xml:"
echo "    gh release create v$VERSION \"$DMG\" \"$DIST/Rounds-$VERSION.zip\" --repo Rounds-Org/rounds --title \"Rounds $VERSION\" --notes \"…\""
echo "    git add appcast.xml && git commit -m \"appcast v$VERSION\" && git push"
echo "  Sparkle needs appcast.xml live on main AND the .zip URL reachable for auto-update to work."
