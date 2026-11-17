#!/usr/bin/env bash
# tools/package/ls-cleanup.sh <app.conf> — leave exactly one LaunchServices record for BUNDLE_ID:
# INSTALL_DIR/<APP_NAME>.app. Swift Glance's scripts/ls-cleanup.sh made project-agnostic: a
# targeted `lsregister -u` of the staged build product and of any mounted /Volumes/<APP_NAME>*
# copy (a mounted disk image is ejected first; a real drive never), nothing else. Never touches the
# installed copy, never runs -kill, -r, -delete or any database rebuild. Exit 1 when a record other
# than the installed copy remains (listed, not removed: look at it by hand).
. "$(dirname "$0")/lib.sh"
kit_load "${1:-}"
set +e

list() {
    "$LSR" -dump 2>/dev/null | awk -v want="$BUNDLE_ID" '
        /^-+$/ { if (p != "" && id == want && p ~ /\.app$/) print p; p=""; id=""; next }
        /^path:/ { sub(/^path:[ \t]+/, ""); sub(/ \(0x[0-9a-fA-F]+\)$/, ""); p=$0 }
        /^identifier:/ { sub(/^identifier:[ \t]+/, ""); id=$0 }
        END { if (p != "" && id == want && p ~ /\.app$/) print p }' | sort -u
}

echo "==> LaunchServices records for $BUNDLE_ID before:"
list | sed 's/^/    /'
while IFS= read -r path; do
    [ -n "$path" ] || continue
    case "$path" in
        "$KEEP") ;;
        "$APP"|"$STAGE_DIR"/*)
            "$LSR" -u "$path" && echo "    unregistered build product: $path" ;;
        /Volumes/"$APP_NAME"*/"$APP_NAME".app)
            vol="/Volumes/$(echo "${path#/Volumes/}" | cut -d/ -f1)"
            if [ -d "$vol" ] && hdiutil info | grep -qF "$vol"; then
                hdiutil detach "$vol" -quiet && echo "    ejected disk image: $vol" || echo "    could not eject $vol (in use?)"
            fi
            "$LSR" -u "$path" && echo "    unregistered DMG copy: $path" ;;
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
