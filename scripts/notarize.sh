#!/usr/bin/env bash
#
# Hardened-runtime sign + notarize + staple build/"Censor Audio.app" for
# distribution, then produce a stapled CensorAudio.zip. Run after ./run.sh.
#
# One-time credential setup (app-specific password from appleid.apple.com →
# Sign-In and Security → App-Specific Passwords):
#   xcrun notarytool store-credentials notarytool-creds \
#     --apple-id "<your-apple-id>" --team-id 92JVKG2EZK --password "<app-specific-pw>"

set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HERE/build/Censor Audio.app"
ZIP="$HERE/CensorAudio.zip"
DEVID="Developer ID Application: Ashu Desai (92JVKG2EZK)"
ENT="$HERE/macos-app/Resources/SwearFilter.entitlements"
CREDS="${NOTARY_PROFILE:-notarytool-creds}"

[[ -d "$APP" ]] || { echo "error: $APP not found — run ./run.sh first." >&2; exit 1; }

# A running instance keeps the dylib mapped, which makes codesign fail with
# "internal error in Code Signing subsystem". Quit it first.
pkill -f "Censor Audio.app/Contents/MacOS/SwearFilter" 2>/dev/null || true
sleep 1

echo "==> re-sign with hardened runtime (Developer ID)"
codesign --force --options runtime --timestamp --sign "$DEVID" "$APP/Contents/Frameworks/"*.dylib
codesign --force --options runtime --timestamp --sign "$DEVID" \
  --identifier com.swearfilter.SwearFilter --entitlements "$ENT" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "==> submit to notary service (waits for result)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$CREDS" --wait

echo "==> staple + verify"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vv "$APP" || true   # should report: accepted, source=Notarized Developer ID

echo "==> re-zip the stapled app for distribution"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Done — $ZIP is notarized + stapled (double-click opens with no warning)."
