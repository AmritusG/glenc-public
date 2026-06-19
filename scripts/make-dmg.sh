#!/usr/bin/env bash
set -euo pipefail

# Build a distributable DMG from the signed + notarized GlEnc.app.
# Output: GlEnc-vX.Y.Z.dmg in the project root.
#
# Layout inside the DMG:
#   /GlEnc.app
#   /Applications -> /Applications  (symlink, lets user drag-drop install)
#
# Run AFTER scripts/build.sh + scripts/sign.sh + scripts/notarize.sh have
# produced a stapled, notarized GlEnc.app. The DMG itself is signed with
# the same Developer ID so Gatekeeper accepts it.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/GlEnc.app"
[ -d "$APP" ] || { echo "GlEnc.app not found at $APP — build + sign + notarize first."; exit 1; }

# Pull version from Info.plist so the filename matches the build.
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="$ROOT/GlEnc-v${VERSION}.dmg"
STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

echo "==> Staging DMG contents at $STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

# Verify staged app is still notarized (cp shouldn't break it but we check).
if ! spctl --assess --type execute --verbose "$STAGING/GlEnc.app" 2>&1 | grep -q "accepted"; then
    echo "WARNING: staged GlEnc.app is not Gatekeeper-accepted. Continuing anyway."
fi

echo "==> Building DMG: $DMG"
rm -f "$DMG"
hdiutil create \
    -volname "GlEnc ${VERSION}" \
    -srcfolder "$STAGING" \
    -ov \
    -format UDZO \
    "$DMG"

# Sign the DMG itself so the user's first Gatekeeper check on download
# resolves cleanly. Uses the same signing identity as the .app —
# required from the environment (no default), mirroring sign.sh/install.sh.
if [ -z "${SIGNING_IDENTITY:-}" ]; then
    cat <<EOF
ERROR: SIGNING_IDENTITY is not set.
make-dmg.sh signs the DMG and needs your Developer ID signing identity:
  SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' $0
List available identities:
  security find-identity -v -p codesigning
EOF
    exit 1
fi
echo "==> Signing DMG"
codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG"

echo "==> Verifying"
spctl --assess --type open --context context:primary-signature --verbose "$DMG" 2>&1 || true

echo
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
echo
echo "Optional next step: notarize the DMG itself (Apple recommends this"
echo "for distributables that contain a notarized app):"
echo "    APPLE_ID=... APPLE_TEAM_ID=... APPLE_PASSWORD=... \\"
echo "    xcrun notarytool submit '$DMG' --apple-id \"\$APPLE_ID\" \\"
echo "        --team-id \"\$APPLE_TEAM_ID\" --password \"\$APPLE_PASSWORD\" --wait"
echo "    xcrun stapler staple '$DMG'"
