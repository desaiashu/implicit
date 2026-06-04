#!/usr/bin/env bash
#
# Build, bundle, sign and launch the Implicit menubar app.
#
#   ./run.sh
#
# Produces build/Censor Audio.app — a self-contained, signed menubar agent (no dock
# icon) with the Whisper model bundled inside. Tuning (mute/bleep, output delay,
# tail, word list) is done from the menubar; settings persist across launches.
# Detection needs the model: run ./scripts/fetch-model.sh once. Without it the
# app runs as a transparent delay.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$HERE/rust-core/models"
RELEASE="$HERE/rust-core/target/release"
WHISPER_MODEL="$MODELS_DIR/ggml-small.en.bin"

command -v cargo >/dev/null || { echo "error: Rust not found — install via https://rustup.rs" >&2; exit 1; }
command -v swift >/dev/null || { echo "error: swift not found — install Xcode or the Command Line Tools" >&2; exit 1; }

FEATURES=()
if [[ -f "$WHISPER_MODEL" ]]; then
  echo "==> whisper model found — building with detection"
  FEATURES=(--features whisper)
else
  echo "==> no model installed — app will run as a transparent delay"
  echo "    (run ./scripts/fetch-model.sh once to enable detection)"
fi

echo "==> building Rust core (this compiles whisper.cpp the first time)"
( cd "$HERE/rust-core" && cargo build --release ${FEATURES[@]+"${FEATURES[@]}"} )

echo "==> building app binary"
swift build --package-path "$HERE/macos-app"
BIN_DIR="$(swift build --package-path "$HERE/macos-app" --show-bin-path)"

echo "==> packaging Censor Audio.app"
APP="$HERE/build/Censor Audio.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/SwearFilter" "$APP/Contents/MacOS/SwearFilter"
cp "$HERE/macos-app/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/macos-app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the Whisper model + the default word list. The app points
# SWEAR_WHISPER_MODEL here and seeds its editable word list from swears.txt.
[[ -f "$WHISPER_MODEL" ]] && cp "$WHISPER_MODEL" "$APP/Contents/Resources/ggml-small.en.bin"
cp "$HERE/scripts/swears.txt" "$APP/Contents/Resources/swears.txt"

# Bundle libswearcore (whisper.cpp + Metal are statically linked into it, so
# there are no other native dylibs to ship) and repoint the binary at
# @rpath/Frameworks. install_name_tool must run before signing.
cp "$RELEASE/libswearcore.dylib" "$APP/Contents/Frameworks/"
OLD_REF="$(otool -L "$APP/Contents/MacOS/SwearFilter" | awk '/libswearcore/{print $1; exit}')"
[[ -n "$OLD_REF" ]] && install_name_tool -change "$OLD_REF" "@rpath/libswearcore.dylib" "$APP/Contents/MacOS/SwearFilter"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/SwearFilter"

echo "==> signing"
SIGN_ID="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/{print $2; exit}')"
if [[ -z "$SIGN_ID" ]]; then
  echo "    no 'Apple Development' identity found; signing ad-hoc (TCC grant won't persist across rebuilds)" >&2
  SIGN_ID="-"
fi
# Nested code first (dylibs), then the app bundle with its entitlements; TCC
# keys the system-audio grant on the bundle identifier + this signing identity.
codesign --force --sign "$SIGN_ID" "$APP/Contents/Frameworks/"*.dylib
codesign --force --sign "$SIGN_ID" \
  --identifier com.swearfilter.SwearFilter \
  --entitlements "$HERE/macos-app/Resources/SwearFilter.entitlements" \
  "$APP"

echo "==> launching Censor Audio (look for the ear icon in the menubar)"
# Relaunch cleanly if a previous build is still running.
pkill -f "Censor Audio.app/Contents/MacOS/SwearFilter" 2>/dev/null || true
# Refresh LaunchServices so `open` doesn't hit a stale registration (-600) after
# repeated rebuilds.
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"
[[ -x "$LSREGISTER" ]] && "$LSREGISTER" -f "$APP" 2>/dev/null || true
# `open` occasionally returns -600 (stale LaunchServices state after many
# rebuilds); fall back to launching the binary directly.
open "$APP" 2>/dev/null || ( "$APP/Contents/MacOS/SwearFilter" &>/dev/null & )
