#!/usr/bin/env bash
set -euo pipefail

# Install the locally-built GlEnc.app to /Applications/GlEnc.app.
#
# Why this script exists: modern macOS (Sonoma+/Sequoia) applies
# different LaunchServices / IconServices policy based on bundle
# location. Apps under /Applications get the full icon-rendering
# pipeline (Cmd-Tab shows the real icon); apps anywhere else —
# particularly under ~/Documents, ~/Desktop, ~/Downloads, or dev
# trees — get a restricted icon path and Cmd-Tab falls back to a
# generic placeholder. Dock and Finder are lenient and render the
# icon correctly regardless of location, so the bug is invisible
# during dev. See CLAUDE.md ("macOS app icon Cmd-Tab visibility")
# and the empirical write-up at memory/feedback_macos_app_location.md.
#
# This script always rm -rf's the staging GlEnc.app, re-assembles
# from scratch via build.sh, signs, copies to /Applications, and
# refreshes LaunchServices. The rm -rf + rebuild eliminates the
# .cstemp codesign race that surfaced during v0.9.2 development: an
# interrupted prior signing leaves CodeResources.cstemp inside
# _CodeSignature/, and the next codesign --force --deep trips on it.
# Forcing a clean assembly on every install kills that class of bug.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/GlEnc.app"
DEST="/Applications/GlEnc.app"
BUILD_SH="$ROOT/scripts/build.sh"
SIGN_SH="$ROOT/scripts/sign.sh"

# ---- Preflight 1: SIGNING_IDENTITY must be present in the environment.
#
# This script is non-interactive — when invoked from a different shell
# (CI runner, makefile, IDE task), it will NOT inherit your ~/.zshrc
# `export SIGNING_IDENTITY=…`. We fail loud and immediately rather than
# letting sign.sh print its (less specific) usage block several seconds
# in. Pass inline if your shell config isn't sourced:
#   SIGNING_IDENTITY="Developer ID …" scripts/install.sh
if [ -z "${SIGNING_IDENTITY:-}" ]; then
    cat >&2 <<EOF
ERROR: SIGNING_IDENTITY is not set.

scripts/install.sh needs SIGNING_IDENTITY exported in the environment.
A non-interactive shell does not source ~/.zshrc, so even if you have
it in your shell config, this invocation context may not see it.

Fix one of:
  (a) Export in your shell startup file and launch this from a fresh
      interactive shell:
          export SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)"
  (b) Pass inline:
          SIGNING_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/install.sh

List available codesigning identities:
  security find-identity -v -p codesigning
EOF
    exit 1
fi

# ---- Preflight 2: required sibling scripts present and executable.
[ -x "$BUILD_SH" ] || { echo "ERROR: $BUILD_SH missing or not executable" >&2; exit 1; }
[ -x "$SIGN_SH" ]  || { echo "ERROR: $SIGN_SH missing or not executable"  >&2; exit 1; }

# ---- Step 1: nuke the staging bundle.
#
# This is the bugfix. codesign --force --deep on a previously-signed
# bundle can leave CodeResources.cstemp inside _CodeSignature/ when
# the prior run was interrupted (or when sign.sh's nested-framework
# loop's `|| true` swallowed a partial failure). Subsequent codesigns
# then fail cryptically. rm -rf + clean re-assembly via build.sh
# guarantees we always sign a pristine bundle.
echo "==> Removing stale staging bundle ($APP)"
rm -rf "$APP"

# ---- Step 2: re-assemble from scratch.
#
# build.sh does swift build + bundle assembly + framework embedding.
# For incremental dev builds swift's compiler cache makes this fast
# in practice; full first build is a couple of minutes.
echo "==> Running scripts/build.sh"
"$BUILD_SH"

# ---- Preflight 3: post-build verification — build.sh must have produced $APP.
#
# If swift build failed before, set -e would have caught it. This guard
# is for the case where build.sh succeeded but didn't produce the bundle
# at the expected path (e.g., its inner BIN/BIN_ALT lookup found the
# binary at a path we don't expect).
if [ ! -d "$APP" ]; then
    cat >&2 <<EOF
ERROR: scripts/build.sh completed but $APP does not exist.

This means build.sh's bundle-assembly step is broken — investigate
its output above. install.sh refuses to proceed with no bundle to
install.
EOF
    exit 1
fi

# ---- Step 3: sign the fresh bundle.
#
# sign.sh reads SIGNING_IDENTITY from env (we verified it above).
# Letting full output through this time — failures here are exactly
# what we need to see in their entirety.
echo "==> Signing $APP"
"$SIGN_SH"

# ---- Step 4: quit any running instance so cp -R doesn't fail busy.
echo "==> Quitting any running GlEnc"
osascript -e 'tell application "GlEnc" to quit' 2>/dev/null || true
sleep 1
pkill -f "GlEnc.app/Contents/MacOS/GlEnc" 2>/dev/null || true
sleep 0.5

# ---- Step 5: remove existing /Applications copy.
#
# Replace rather than overlay so stale files from a previous build
# (renamed resources, retired frameworks) don't linger.
if [ -d "$DEST" ]; then
    echo "==> Removing existing $DEST"
    rm -rf "$DEST"
fi

# ---- Step 6: install.
echo "==> Copying $APP → $DEST"
cp -R "$APP" "$DEST"

# ---- Step 7: post-install codesign verification (with exit-status check).
#
# The previous script piped this through `tail -3`, which under bash's
# default pipe-exit-status behavior discards codesign's exit code and
# always returns tail's (0). A failed verification would print to
# stderr but not fail the script. Capture the status explicitly here.
echo "==> Verifying codesign on $DEST"
if ! codesign --verify --deep --strict --verbose=2 "$DEST"; then
    cat >&2 <<EOF
ERROR: codesign --verify --deep --strict FAILED on $DEST.

The bundle was copied but does not verify. Do NOT trust this install.
Inspect the codesign output above and re-run after resolving.
EOF
    exit 1
fi

# ---- Step 8: confirm install location actually has the bundle.
#
# Belt-and-suspenders: a partial cp -R failure under set -e would have
# aborted us already, but the success line below is a hard claim and
# we want it backed by a check.
if [ ! -d "$DEST" ]; then
    echo "ERROR: $DEST does not exist after install" >&2
    exit 1
fi

# ---- Step 9: refresh LaunchServices + Dock so Cmd-Tab sees the new bundle.
echo "==> Registering with LaunchServices"
/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DEST"

echo "==> Refreshing Dock (so Cmd-Tab picks up the new icon)"
killall Dock 2>&1 || true

# ---- Step 10: explicit success line.
#
# A partial install must not look the same as success. Anything that
# bails above exits nonzero; reaching this point means every
# preceding step succeeded.
cat <<EOF

==> SUCCESS — GlEnc installed at $DEST

Launch from /Applications, Spotlight, or:
    open $DEST

The icon should now render correctly in Cmd-Tab. The dev build at
$APP still launches fine — it just gets the placeholder icon in
Cmd-Tab because of macOS path policy.
EOF
