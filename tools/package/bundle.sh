#!/usr/bin/env bash
# tools/package/bundle.sh <app.conf> — build the app universal (arm64 + x86_64, macOS MIN_MACOS)
# and assemble <STAGE_DIR>/<APP_NAME>.app: the lipo'd binary, Info.plist from the template with the
# slots filled, the icon when ICON is set. Refuses when the plist's two version fields differ (Swift
# Glance's build.sh rule, v0.18.1: LaunchServices compares CFBundleVersion).
#
# The Rust toolchain must have the std of both macOS targets; KIT_TOOLCHAIN_BIN points at one
# (default: the toolchain on PATH when it has both, else rustup's stable).
. "$(dirname "$0")/lib.sh"
kit_load "${1:-}"

bin_dir="${KIT_TOOLCHAIN_BIN:-}"
if [ -z "$bin_dir" ]; then
    if [ -d "$(rustc --print sysroot)/lib/rustlib/x86_64-apple-darwin" ] && [ -d "$(rustc --print sysroot)/lib/rustlib/aarch64-apple-darwin" ]; then
        bin_dir="$(dirname "$(command -v cargo)")"
    else
        bin_dir="$HOME/.rustup/toolchains/stable-$(uname -m | sed 's/arm64/aarch64/')-apple-darwin/bin"
    fi
fi
[ -x "$bin_dir/cargo" ] && [ -x "$bin_dir/rustc" ] || kit_die "no cargo / rustc in $bin_dir (set KIT_TOOLCHAIN_BIN)"
echo "==> toolchain: $("$bin_dir/rustc" --version)"

target_dir="$STAGE_DIR/target"
mkdir -p "$STAGE_DIR"
for t in aarch64-apple-darwin x86_64-apple-darwin; do
    echo "==> cargo build --release --target $t -p $CARGO_PACKAGE"
    (cd "$REPO" && MACOSX_DEPLOYMENT_TARGET="$MIN_MACOS" CARGO_TARGET_DIR="$target_dir" RUSTC="$bin_dir/rustc" "$bin_dir/cargo" build --release --locked --target "$t" -p "$CARGO_PACKAGE" --bin "$EXECUTABLE")
done

echo "==> assembling $APP"
case "$APP" in */"$APP_NAME".app) ;; *) kit_die "odd bundle path $APP";; esac
if [ -e "$APP" ]; then rm -r "$APP"; fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create -output "$APP/Contents/MacOS/$EXECUTABLE" "$target_dir/aarch64-apple-darwin/release/$EXECUTABLE" "$target_dir/x86_64-apple-darwin/release/$EXECUTABLE"
# Debug information out of the shipped binary, the symbol table kept (crash reports keep function names): Apple's
# `strip -S` on the universal file. Cargo's `strip = "debuginfo"` runs rustup's rust-objcopy, which on rustc 1.100
# cannot load (it looks for libLLVM.dylib beside itself, not in the toolchain's lib/) and only warns (v0.4.0).
strip -S "$APP/Contents/MacOS/$EXECUTABLE"
stabs="$(nm -a "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null | grep -c ' - ' || true)"
[ "$stabs" = 0 ] || kit_die "debug map entries left after strip -S: $stabs"
sed -e "s|@APP_NAME@|$APP_NAME|g" -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" -e "s|@EXECUTABLE@|$EXECUTABLE|g" -e "s|@VERSION@|$VERSION|g" -e "s|@MIN_MACOS@|$MIN_MACOS|g" \
    "$CONF_DIR/$INFO_PLIST" > "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null
short="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
long="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[ "$short" = "$long" ] || kit_die "CFBundleVersion ($long) != CFBundleShortVersionString ($short): set both to the release version"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")" = "$BUNDLE_ID" ] || kit_die "Info.plist bundle id is not $BUNDLE_ID"
if [ -n "${ICON:-}" ]; then
    cp -p "$CONF_DIR/$ICON" "$APP/Contents/Resources/AppIcon.icns"
fi
echo "==> stripped: 0 debug map entries, $(nm "$APP/Contents/MacOS/$EXECUTABLE" 2>/dev/null | wc -l | tr -d ' ') symbols kept"
echo "==> $APP: version $short, $(lipo -archs "$APP/Contents/MacOS/$EXECUTABLE"), minos $(otool -l "$APP/Contents/MacOS/$EXECUTABLE" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
