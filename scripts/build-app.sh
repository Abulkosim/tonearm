#!/usr/bin/env bash
# Builds a universal (arm64 + x86_64) Tonearm.app into build/, with Sparkle.framework
# in Contents/Frameworks, and signs it inside-out.
#
# Environment:
#   VERSION        CFBundleShortVersionString. Default: the value in Resources/Info.plist.
#   BUILD          CFBundleVersion. Default: the value in Resources/Info.plist.
#   SIGN_IDENTITY  codesign identity: "-" (ad-hoc, the default), "Tonearm Self-Signed",
#                  or "Developer ID Application: ...". Only Developer ID gets a secure timestamp.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="${SIGN_IDENTITY:--}"
APP=build/Tonearm.app
PLIST="$APP/Contents/Info.plist"
FW="$APP/Contents/Frameworks/Sparkle.framework"
plistbuddy=/usr/libexec/PlistBuddy
rpath=@executable_path/../Frameworks
swift_flags=(-c release --arch arm64 --arch x86_64 -Xlinker -rpath -Xlinker "$rpath")

swift build "${swift_flags[@]}"
BIN="$(swift build "${swift_flags[@]}" --show-bin-path)/Tonearm"

# The macOS slice of the xcframework SwiftPM downloaded for the pinned Sparkle version.
sparkle_src="$(find .build/artifacts -type d -path '*/Sparkle.xcframework/macos-*/Sparkle.framework' -prune | head -n 1)"
[ -n "$sparkle_src" ] || { echo "Sparkle.framework not found under .build/artifacts" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/Tonearm"
cp Resources/Info.plist "$PLIST"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
# ditto keeps the framework's Versions/Current symlinks.
ditto "$sparkle_src" "$FW"
# Sparkle's XPC services are only for sandboxed apps. Tonearm is not sandboxed.
rm -rf "$FW/XPCServices" "$FW/Versions/"*/XPCServices

load_commands="$(otool -l "$APP/Contents/MacOS/Tonearm")"
if ! grep -A2 LC_RPATH <<< "$load_commands" | grep -qF "path $rpath "; then
  echo "the binary has no $rpath rpath; dyld would not find Sparkle" >&2
  exit 1
fi

if [ -n "${VERSION:-}" ]; then
  "$plistbuddy" -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi
if [ -n "${BUILD:-}" ]; then
  "$plistbuddy" -c "Set :CFBundleVersion $BUILD" "$PLIST"
fi
plutil -lint "$PLIST"

# Developer ID builds get the hardened runtime, which notarization requires, and a
# timestamp. Apple Events under the hardened runtime need the automation.apple-events
# entitlement.
# Ad-hoc and self-signed builds get neither. The hardened runtime turns on library
# validation, which only loads frameworks signed with the app's Team ID, and these
# signatures have no Team ID: dyld refuses Sparkle.framework and the app dies at
# launch (v0.3.0). Apple's timestamp server only serves Developer IDs.
case "$SIGN_IDENTITY" in
  "Developer ID Application:"*) options=(--options runtime --timestamp) ;;
  *) options=(--timestamp=none) ;;
esac
sign() {
  codesign --force "${options[@]}" --sign "$SIGN_IDENTITY" "$@"
}
# Inside-out: Sparkle's helpers, the framework, then the app. No --deep.
fw_version="$(readlink "$FW/Versions/Current")"
sign "$FW/Versions/$fw_version/Autoupdate"
sign "$FW/Versions/$fw_version/Updater.app"
sign "$FW"
sign --entitlements Resources/Tonearm.entitlements "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "version: $("$plistbuddy" -c 'Print :CFBundleShortVersionString' "$PLIST") ($("$plistbuddy" -c 'Print :CFBundleVersion' "$PLIST"))"
echo "archs: $(lipo -archs "$APP/Contents/MacOS/Tonearm"), Sparkle: $(lipo -archs "$FW/Versions/$fw_version/Sparkle")"
echo "Sparkle: $("$plistbuddy" -c 'Print :CFBundleShortVersionString' "$FW/Resources/Info.plist")"
codesign -dv --entitlements - "$APP" 2>&1
codesign -d -r- "$APP" 2>&1 | grep designated || true
echo "built $APP"
