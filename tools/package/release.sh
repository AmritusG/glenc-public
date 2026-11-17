#!/usr/bin/env bash
# tools/package/release.sh <app.conf> — the whole macOS chain in order: bundle (universal), sign,
# notarise + staple the app, DMG (signed, notarised, stapled, .sha256), ls-cleanup. Installing
# (install.sh) and publishing are separate steps the app's own release brief names.
. "$(dirname "$0")/lib.sh"
kit_load "${1:-}"
here="$(dirname "$0")"
"$here/bundle.sh" "$1"
"$here/sign.sh" "$1"
"$here/notarize.sh" "$1"
"$here/dmg.sh" "$1"
"$here/ls-cleanup.sh" "$1" || echo "kit: ls-cleanup found records it left alone (above)" >&2
