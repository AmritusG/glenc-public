#!/usr/bin/env bash
set -euo pipefail

# GlEnc icon build script.
# Re-renders GlEnc.icns from the master SVG at assets/GlEnc-icon.svg.
# Run after editing the master SVG. Outputs assets/GlEnc.icns.
#
# Requires: rsvg-convert (brew install librsvg), iconutil (built into macOS).

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/assets/GlEnc-icon.svg"
ICONSET="$ROOT/assets/GlEnc.iconset"
ICNS="$ROOT/assets/GlEnc.icns"

[ -f "$SVG" ] || { echo "Master SVG missing: $SVG"; exit 1; }
command -v rsvg-convert >/dev/null || { echo "rsvg-convert missing — brew install librsvg"; exit 1; }
command -v iconutil >/dev/null || { echo "iconutil missing — install Xcode CLT"; exit 1; }

echo "==> Rendering icon sizes from $(basename "$SVG")"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# .iconset directory layout iconutil requires. Filenames are exact.
# Both @1x and @2x are needed for each logical size.
declare -a sizes=(
    "16    icon_16x16.png"
    "32    icon_16x16@2x.png"
    "32    icon_32x32.png"
    "64    icon_32x32@2x.png"
    "128   icon_128x128.png"
    "256   icon_128x128@2x.png"
    "256   icon_256x256.png"
    "512   icon_256x256@2x.png"
    "512   icon_512x512.png"
    "1024  icon_512x512@2x.png"
)

for entry in "${sizes[@]}"; do
    px="${entry%% *}"
    name="${entry##* }"
    rsvg-convert -w "$px" -h "$px" "$SVG" -o "$ICONSET/$name"
done

echo "==> Building $ICNS"
iconutil -c icns "$ICONSET" -o "$ICNS"
rm -rf "$ICONSET"
echo "==> Done: $ICNS ($(stat -f%z "$ICNS") bytes)"
