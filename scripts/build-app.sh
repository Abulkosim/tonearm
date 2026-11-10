#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) Tonearm.app into build/.
#
# Environment:
#   VERSION        CFBundleShortVersionString. Default: the value in Resources/Info.plist.
#   BUILD          CFBundleVersion. Default: the value in Resources/Info.plist.
#   SIGN_IDENTITY  codesign identity. "-" (ad-hoc, the default) or "Developer ID Application: ...".
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP=build/Tonearm.app
PLIST="$APP/Contents/Info.plist"
plistbuddy=/usr/libexec/PlistBuddy

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tonearm"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tonearm"
cp Resources/Info.plist "$PLIST"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

if [ -n "${VERSION:-}" ]; then
  "$plistbuddy" -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi
if [ -n "${BUILD:-}" ]; then
  "$plistbuddy" -c "Set :CFBundleVersion $BUILD" "$PLIST"
fi
plutil -lint "$PLIST"

# Hardened runtime is required for notarization. Apple Events under the hardened
# runtime need the automation.apple-events entitlement.
if [ "$SIGN_IDENTITY" = "-" ]; then
  timestamp=(--timestamp=none)
else
  timestamp=(--timestamp)
fi
codesign --force --options runtime "${timestamp[@]}" \
  --entitlements Resources/Tonearm.entitlements \
  --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "version: $("$plistbuddy" -c 'Print :CFBundleShortVersionString' "$PLIST") ($("$plistbuddy" -c 'Print :CFBundleVersion' "$PLIST"))"
echo "archs: $(lipo -archs "$APP/Contents/MacOS/Tonearm")"
codesign -dv --entitlements - "$APP" 2>&1
echo "built $APP"
