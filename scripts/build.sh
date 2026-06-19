#!/usr/bin/env bash
set -euo pipefail

# Build script adapted from Glance v0.4.13. Produces GlEnc.app at the
# project root from a fresh `swift build` output.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT/.build"
APP_DIR="$ROOT/GlEnc.app"
SCHEME="GlEnc"
CONFIG="${CONFIG:-release}"
ICNS="$ROOT/assets/GlEnc.icns"

case "$CONFIG" in
    release) CONFIG_DIR="release" ;;
    debug)   CONFIG_DIR="debug" ;;
    *)       CONFIG_DIR="$CONFIG" ;;
esac

cd "$ROOT"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$BUILD_DIR/$CONFIG_DIR/$SCHEME"
if [ ! -f "$BIN" ]; then
    BIN_ALT="$BUILD_DIR/apple/Products/$(echo "$CONFIG_DIR" | awk '{print toupper(substr($0,1,1)) substr($0,2)}')/$SCHEME"
    if [ -f "$BIN_ALT" ]; then
        BIN="$BIN_ALT"
    else
        echo "Built binary not found at $BIN or $BIN_ALT"
        exit 1
    fi
fi

echo "==> Assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$APP_DIR/Contents/Frameworks"
cp "$BIN" "$APP_DIR/Contents/MacOS/$SCHEME"
cp "$ROOT/Sources/GlEnc/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/$SCHEME"

# Embed app icon if available. Info.plist references CFBundleIconFile=AppIcon,
# so the .icns must land at Contents/Resources/AppIcon.icns. Skip with a
# warning if the icon hasn't been derived from the SVG yet.
if [ -f "$ICNS" ]; then
    echo "==> Embedding app icon"
    cp "$ICNS" "$APP_DIR/Contents/Resources/AppIcon.icns"
else
    echo "==> No app icon found ($ICNS missing — run scripts/build-icon.sh once added)"
fi

PKG_DIR="$BUILD_DIR/$CONFIG_DIR"
if [ -d "$PKG_DIR" ]; then
    find "$PKG_DIR" -name '*.framework' -maxdepth 2 -type d 2>/dev/null | while read -r fw; do
        echo "==> Bundling framework: $(basename "$fw")"
        cp -R "$fw" "$APP_DIR/Contents/Frameworks/"
    done
fi

echo "==> Built $APP_DIR"
echo "Run: open '$APP_DIR'"
