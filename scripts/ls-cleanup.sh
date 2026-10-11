#!/usr/bin/env bash
# ls-cleanup.sh — leave exactly one LaunchServices record for GlEnc: /Applications/GlEnc.app.
#
# Every build / sign / notarize / spctl registers another copy of com.amritus.glenc with
# LaunchServices (a source tree's ./GlEnc.app), and every mounted release DMG registers
# /Volumes/GlEnc x.y.z/GlEnc.app. macOS then lists several GlEncs in Open With. This script
# unregisters, with a targeted `lsregister -u` only:
#   (a) the build product of any GlEnc source tree: a record <dir>/GlEnc.app whose <dir> holds
#       scripts/build.sh and Sources/GlEnc (this checkout, its public mirror, a worktree; the
#       record may outlive the deleted bundle)
#   (b) any /Volumes/GlEnc*/GlEnc.app record (a mounted disk image is ejected first; a real
#       drive is never ejected)
# It never touches /Applications/GlEnc.app and never runs -kill, -r, -delete or any other
# database rebuild. Exit 1 when a com.amritus.glenc record other than /Applications/GlEnc.app
# remains afterwards (it is listed, not removed: look at it by hand).
#
# Run it at the end of every release (after the install into /Applications and after the DMG is
# detached) and after any DMG validation launch. make-dmg.sh, install.sh and install-from-dmg.sh
# call it. Same rule as Glance's scripts/ls-cleanup.sh, scoped to GlEnc.
set -uo pipefail

BUNDLE_ID="com.amritus.glenc"
KEEP="/Applications/GlEnc.app"
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

list() {
    "$LSR" -dump 2>/dev/null | awk -v want="$BUNDLE_ID" '
        /^-+$/ { if (p != "" && id == want && p ~ /\.app$/) print p; p=""; id=""; next }
        /^path:/ { sub(/^path:[ \t]+/, ""); sub(/ \(0x[0-9a-fA-F]+\)$/, ""); p=$0 }
        /^identifier:/ { sub(/^identifier:[ \t]+/, ""); id=$0 }
        END { if (p != "" && id == want && p ~ /\.app$/) print p }' | sort -u
}

is_source_tree() {
    [ -f "$1/scripts/build.sh" ] && [ -d "$1/Sources/GlEnc" ]
}

echo "==> LaunchServices records for $BUNDLE_ID before:"
list | sed 's/^/    /'

while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
        "$KEEP") ;;
        /Volumes/GlEnc*/GlEnc.app)
            vol="/Volumes/$(echo "${path#/Volumes/}" | cut -d/ -f1)"
            if [ -d "$vol" ] && hdiutil info | grep -qF "$vol"; then
                hdiutil detach "$vol" -quiet && echo "    ejected disk image: $vol" \
                    || echo "    could not eject $vol (in use?)"
            fi
            "$LSR" -u "$path" && echo "    unregistered DMG copy: $path" ;;
        */GlEnc.app)
            if is_source_tree "$(dirname "$path")"; then
                "$LSR" -u "$path" && echo "    unregistered build product: $path"
            else
                echo "    left alone (not a build product or DMG copy): $path"
            fi ;;
        *) echo "    left alone (not a build product or DMG copy): $path" ;;
    esac
done < <(list)

echo "==> LaunchServices records for $BUNDLE_ID after:"
after="$(list)"
echo "$after" | sed 's/^/    /'
if [ "$after" != "$KEEP" ]; then
    echo "WARNING: expected exactly one record ($KEEP)." >&2
    exit 1
fi
echo "==> OK: exactly one record ($KEEP)"
