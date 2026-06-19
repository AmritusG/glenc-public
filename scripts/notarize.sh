#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/GlEnc.app"

# Uses the "amritus-notary" Keychain profile (stored via
# `xcrun notarytool store-credentials amritus-notary`).
# No env vars required.

[ -d "$APP" ] || { echo "Build + sign first: scripts/build.sh && scripts/sign.sh"; exit 1; }

# notarytool only accepts ZIP, DMG, or PKG. We zip the .app, submit,
# wait for the result, then staple the notarization ticket back onto the
# .app so it works offline.
ZIP="$ROOT/GlEnc-notarize.zip"

echo "==> Zipping $APP for submission"
rm -f "$ZIP"
# ditto preserves macOS metadata and code signatures inside the zip
# better than `zip -r`. xcrun notarytool requires this.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting to Apple notarization service (this can take 1-30 min)"
xcrun notarytool submit "$ZIP" \
    --keychain-profile "amritus-notary" \
    --wait

echo "==> Stapling notarization ticket to $APP"
xcrun stapler staple "$APP"

echo "==> Verifying staple"
xcrun stapler validate "$APP"

echo "==> Verifying Gatekeeper acceptance"
spctl --assess --type execute --verbose "$APP"

echo "==> Done. Cleanup:"
rm -f "$ZIP"
echo "    Removed $ZIP"
