#!/usr/bin/env bash
# install-from-dmg.sh — the release's DMG validation + install, then LaunchServices cleanup.
#
#   scripts/install-from-dmg.sh path/to/GlEnc-vX.Y.Z.dmg   (the notarized release DMG)
#
# Mounts the DMG read-only, checks Gatekeeper on its GlEnc.app, launches it for 7 s, quits it,
# replaces /Applications/GlEnc.app with it (ditto), detaches the DMG, checks Gatekeeper and the
# stapled ticket on the installed app, launches it for 7 s, refreshes the Dock (Cmd-Tab icon, as
# install.sh does) and finally runs scripts/ls-cleanup.sh, so /Applications/GlEnc.app is the only
# LaunchServices record for com.amritus.glenc afterwards (the mount registered another).
# Nothing in /Applications is touched until the mounted GlEnc.app has been found and accepted.
#
# This installs a RELEASE. scripts/install.sh installs a development build from this tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DMG="${1:?usage: install-from-dmg.sh path/to/GlEnc-vX.Y.Z.dmg}"
[ -f "$DMG" ] || { echo "No such DMG: $DMG"; exit 1; }

quit_glenc() {
    osascript -e 'tell application id "com.amritus.glenc" to quit' >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        pgrep -f "GlEnc.app/Contents/MacOS/GlEnc$" >/dev/null || return 0
        sleep 1
    done
    echo "GlEnc did not quit; quit it and run again." >&2
    exit 1
}

echo "==> Mounting $DMG"
MOUNT="$(hdiutil attach -nobrowse -readonly "$DMG" | awk -F'\t' '/\/Volumes\// { print $NF }' | tail -1)"
[ -n "$MOUNT" ] && [ -d "$MOUNT/GlEnc.app" ] || { echo "GlEnc.app not found on the mounted DMG ($MOUNT)"; exit 1; }
trap 'hdiutil detach "$MOUNT" -quiet 2>/dev/null || true' EXIT
echo "    $MOUNT"

echo "==> Gatekeeper on the DMG's app"
spctl --assess --type execute --verbose "$MOUNT/GlEnc.app"
VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$MOUNT/GlEnc.app/Contents/Info.plist")"
echo "    version $VERSION"

quit_glenc
echo "==> Launching the DMG's app for 7 s"
open "$MOUNT/GlEnc.app"
sleep 7
pgrep -f "$MOUNT/GlEnc.app/Contents/MacOS/GlEnc" >/dev/null && echo "    running after 7 s" \
    || { echo "DMG app not running after 7 s"; exit 1; }
quit_glenc

echo "==> Installing into /Applications (ditto)"
[ -d /Applications/GlEnc.app ] && echo "    before: $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/GlEnc.app/Contents/Info.plist)"
rm -rf /Applications/GlEnc.app
ditto "$MOUNT/GlEnc.app" /Applications/GlEnc.app
echo "    after:  $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" /Applications/GlEnc.app/Contents/Info.plist)"
hdiutil detach "$MOUNT" -quiet
trap - EXIT
spctl --assess --type execute --verbose /Applications/GlEnc.app
xcrun stapler validate /Applications/GlEnc.app

echo "==> Launching /Applications/GlEnc.app for 7 s"
open /Applications/GlEnc.app
sleep 7
pgrep -f "/Applications/GlEnc.app/Contents/MacOS/GlEnc" >/dev/null && echo "    running after 7 s" \
    || { echo "installed app not running after 7 s"; exit 1; }
killall Dock 2>/dev/null || true

"$ROOT/scripts/ls-cleanup.sh"
