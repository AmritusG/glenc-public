#!/usr/bin/env bash
# tools/package/notarize.sh <app.conf> [path] — submit the signed app (zipped with ditto) or DMG to
# Apple's notary service with the keychain profile NOTARY_PROFILE (stored once by its owner:
# `xcrun notarytool store-credentials <profile>`; never a password on a command line), wait, refuse
# anything but Accepted, staple the ticket, validate it, ask Gatekeeper.
. "$(dirname "$0")/lib.sh"
kit_load "${1:-}"
target="${2:-$APP}"
[ -e "$target" ] || kit_die "nothing to notarise at $target"
work="$(mktemp -d)"
trap 'rm -r "$work"' EXIT
upload="$target"
case "$target" in
    *.app) upload="$work/$(basename "$target" .app).zip"; ditto -c -k --keepParent "$target" "$upload" ;;
esac
echo "==> notarytool submit $(basename "$upload") (profile $NOTARY_PROFILE)"
xcrun notarytool submit "$upload" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json > "$work/notary.json"
status="$(plutil -extract status raw -o - "$work/notary.json" 2>/dev/null || true)"
id="$(plutil -extract id raw -o - "$work/notary.json" 2>/dev/null || true)"
echo "    submission $id: $status"
if [ "$status" != "Accepted" ]; then
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" 2>&1 | kit_mask | head -60 || true
    kit_die "notarisation $status"
fi
echo "==> stapler staple"
xcrun stapler staple "$target"
xcrun stapler validate "$target"
case "$target" in
    *.app) spctl --assess --type execute --verbose=2 "$target" 2>&1 | kit_mask ;;
    *.dmg) spctl --assess --type open --context context:primary-signature --verbose=2 "$target" 2>&1 | kit_mask ;;
esac
