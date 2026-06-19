#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/GlEnc.app"
ENTITLEMENTS="$ROOT/scripts/entitlements.plist"
IDENTITY="${SIGNING_IDENTITY:-${1:-}}"

if [ -z "$IDENTITY" ]; then
    cat <<EOF
Usage:
  SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' $0
  $0 'Developer ID Application: Your Name (TEAMID)'

List available identities:
  security find-identity -v -p codesigning
EOF
    exit 1
fi

[ -d "$APP" ] || { echo "Build first: scripts/build.sh"; exit 1; }
[ -f "$ENTITLEMENTS" ] || { echo "Missing $ENTITLEMENTS"; exit 1; }

echo "==> Signing nested frameworks"
find "$APP/Contents/Frameworks" -type d \( -name '*.framework' -o -name '*.dylib' \) 2>/dev/null | while read -r item; do
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$item" || true
done

echo "==> Signing app bundle"
codesign --force --deep --options runtime --timestamp \
    --sign "$IDENTITY" \
    --entitlements "$ENTITLEMENTS" \
    "$APP"

echo "==> Verifying signature"
codesign --verify --verbose=2 "$APP"
echo "==> Gatekeeper assessment"
spctl --assess --type execute --verbose "$APP" || echo "(spctl will fail until notarized)"

echo "==> Done"
