#!/usr/bin/env bash
# tools/package/sign.sh <app.conf> [path] — Developer ID signature with the hardened runtime and a
# secure timestamp, the kit's entitlements; then a strict verification. Signs the staged app, or
# `path` (a DMG is signed without entitlements).
. "$(dirname "$0")/lib.sh"
kit_load "${1:-}"
target="${2:-$APP}"
[ -e "$target" ] || kit_die "nothing to sign at $target (run bundle.sh first)"
id="$(kit_identity)"
case "$target" in
    *.dmg)
        codesign --force --timestamp --sign "$id" "$target" 2>&1 | kit_mask ;;
    *)
        codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$id" "$target" 2>&1 | kit_mask
        codesign --verify --deep --strict --verbose=2 "$target" 2>&1 | kit_mask
        codesign -d --verbose=2 "$target" 2>&1 | grep -E "^(Identifier|Format|CodeDirectory|Runtime Version|Timestamp|TeamIdentifier)" | kit_mask ;;
esac
