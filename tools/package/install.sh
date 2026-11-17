#!/usr/bin/env bash
# tools/package/install.sh <app.conf> [dmg] — the release's install check: mount the DMG read-only,
# Gatekeeper on its app, copy it into INSTALL_DIR with ditto (replacing only <APP_NAME>.app there),
# detach, Gatekeeper and the stapled ticket on the installed copy, then ls-cleanup.sh.
. "$(dirname "$0")/lib.sh"
kit_load "${1:-}"
dmg="${2:-$DMG}"
[ -f "$dmg" ] || kit_die "no DMG at $dmg"
if pgrep -x "$EXECUTABLE" >/dev/null; then kit_die "$EXECUTABLE is running: quit it first"; fi
mount="$(hdiutil attach -nobrowse -readonly "$dmg" | awk -F'\t' '/\/Volumes\// { print $NF }' | tail -1)"
[ -n "$mount" ] && [ -d "$mount/$APP_NAME.app" ] || kit_die "$APP_NAME.app not found on the mounted DMG ($mount)"
trap 'hdiutil detach "$mount" -quiet 2>/dev/null || true' EXIT
echo "==> Gatekeeper on the DMG's app ($mount)"
spctl --assess --type execute --verbose=2 "$mount/$APP_NAME.app" 2>&1 | kit_mask
mkdir -p "$INSTALL_DIR"
if [ -e "$KEEP" ]; then rm -r "$KEEP"; fi
ditto "$mount/$APP_NAME.app" "$KEEP"
hdiutil detach "$mount" -quiet
trap - EXIT
echo "==> installed $KEEP ($(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$KEEP/Contents/Info.plist"))"
spctl --assess --type execute --verbose=2 "$KEEP" 2>&1 | kit_mask
xcrun stapler validate "$KEEP"
"$(dirname "$0")/ls-cleanup.sh" "$1"
