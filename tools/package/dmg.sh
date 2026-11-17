#!/usr/bin/env bash
# tools/package/dmg.sh <app.conf> — the distributable: a compressed disk image (UDZO) named
# "<APP_NAME> <VERSION>" holding the notarised app and an /Applications link, file
# <APP_NAME>-v<VERSION>.dmg in STAGE_DIR; signed, notarised and stapled itself; then its SHA-256 in
# <dmg>.sha256 (`shasum -a 256`, written after stapling, as Glance's releases do).
. "$(dirname "$0")/lib.sh"
kit_load "${1:-}"
[ -d "$APP" ] || kit_die "no app at $APP"
xcrun stapler validate "$APP" >/dev/null || kit_die "the app is not stapled: notarise it first"
here="$(dirname "$0")"
work="$(mktemp -d)"
trap 'rm -r "$work"' EXIT
ditto "$APP" "$work/$APP_NAME.app"
ln -s /Applications "$work/Applications"
if [ -e "$DMG" ]; then rm "$DMG"; fi
echo "==> hdiutil create $(basename "$DMG")"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$work" -ov -format UDZO "$DMG" >/dev/null
"$here/sign.sh" "$1" "$DMG"
"$here/notarize.sh" "$1" "$DMG"
(cd "$(dirname "$DMG")" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "==> $DMG ($(stat -f %z "$DMG") bytes), sha256 $(cut -d' ' -f1 "$DMG.sha256")"
