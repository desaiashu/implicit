#!/usr/bin/env bash
#
# Build, bundle, sign and launch the Implicit menubar app.
#
#   ./run.sh
#
# Produces build/Implicit.app — a self-contained, signed menubar agent (no
# dock icon) with the keyword model and native dylibs bundled inside. All tuning
# (mute/bleep, output delay, word-length estimate, latency reach-back, tail) is
# done from the menubar popover; settings persist across launches. Detection
# needs a model (rust-core/models/keywords.txt — run ./scripts/fetch-model.sh
# once); without one the app runs as a transparent delay.

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODELS_DIR="$HERE/rust-core/models"
RELEASE="$HERE/rust-core/target/release"

command -v cargo >/dev/null || { echo "error: Rust not found — install via https://rustup.rs" >&2; exit 1; }
command -v swift >/dev/null || { echo "error: swift not found — install Xcode or the Command Line Tools" >&2; exit 1; }

FEATURES=()
if [[ -f "$MODELS_DIR/keywords.txt" ]]; then
  echo "==> model found — building with keyword detection"
  FEATURES=(--features sherpa)
else
  echo "==> no model installed — app will run as a transparent delay"
  echo "    (run ./scripts/fetch-model.sh once to enable detection)"
fi

echo "==> building Rust core"
( cd "$HERE/rust-core" && cargo build --release ${FEATURES[@]+"${FEATURES[@]}"} )

echo "==> building app binary"
swift build --package-path "$HERE/macos-app"
BIN_DIR="$(swift build --package-path "$HERE/macos-app" --show-bin-path)"

echo "==> packaging Implicit.app"
APP="$HERE/build/Implicit.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
cp "$BIN_DIR/SwearFilter" "$APP/Contents/MacOS/SwearFilter"
cp "$HERE/macos-app/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$HERE/macos-app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle the keyword model (whole dir: canonical symlinks + the epoch-named
# files they point at). The app sets SWEAR_KWS_DIR to this path on launch.
[[ -d "$MODELS_DIR" ]] && cp -R "$MODELS_DIR" "$APP/Contents/Resources/models"

# Bundle ALL native dylibs (libswearcore + the sherpa + onnxruntime libs it pulls
# in, all @rpath-linked) so the app is self-contained, and repoint the binary at
# @rpath/Frameworks. install_name_tool must run before signing (it invalidates
# any signature). Copy real files only — skip the libonnxruntime.dylib symlink.
find "$RELEASE" -maxdepth 1 -type f -name '*.dylib' -exec cp {} "$APP/Contents/Frameworks/" \;
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

echo "==> launching Implicit (look for the speaking-person icon in the menubar)"
# Relaunch cleanly if a previous build is still running.
pkill -f "Implicit.app/Contents/MacOS/SwearFilter" 2>/dev/null || true
open "$APP"
