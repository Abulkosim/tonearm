#!/usr/bin/env bash
# Packages build/Tonearm.app (from scripts/build-app.sh) into dist/:
#   Tonearm-<version>.zip, Tonearm-<version>.dmg, SHA256SUMS.txt
#
# Environment:
#   VERSION        File name version. Default: CFBundleShortVersionString of the built app.
#   SIGN_IDENTITY  "-" (default) leaves the dmg unsigned; a Developer ID identity signs it.
#   NOTARIZE       "true" notarizes and staples the app and the dmg (see scripts/notarize.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Tonearm.app
OUT=dist
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
NOTARIZE="${NOTARIZE:-false}"

[ -d "$APP" ] || { echo "missing $APP; run scripts/build-app.sh first" >&2; exit 1; }
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")}"
ZIP="$OUT/Tonearm-$VERSION.zip"
DMG="$OUT/Tonearm-$VERSION.dmg"

if [ "$NOTARIZE" = true ] && [ "$SIGN_IDENTITY" = "-" ]; then
  echo "NOTARIZE=true needs a Developer ID SIGN_IDENTITY" >&2
  exit 1
fi

rm -rf "$OUT"
mkdir -p "$OUT"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ "$NOTARIZE" = true ]; then
  ditto -c -k --keepParent "$APP" "$work/notarize-app.zip"
  scripts/notarize.sh "$work/notarize-app.zip"
  xcrun stapler staple "$APP"
  spctl -a -t exec -vv "$APP"
fi

ditto -c -k --keepParent "$APP" "$ZIP"

mkdir "$work/dmg"
ditto "$APP" "$work/dmg/Tonearm.app"
ln -s /Applications "$work/dmg/Applications"
# hdiutil sometimes fails with "Resource busy" on CI runners; retry.
for attempt in 1 2 3; do
  if hdiutil create -volname Tonearm -srcfolder "$work/dmg" -ov -format UDZO "$DMG"; then
    break
  fi
  [ "$attempt" -lt 3 ] || exit 1
  sleep 5
done

if [ "$SIGN_IDENTITY" != "-" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  codesign --verify --verbose=2 "$DMG"
fi
if [ "$NOTARIZE" = true ]; then
  scripts/notarize.sh "$DMG"
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
fi
hdiutil verify "$DMG"

(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > SHA256SUMS.txt)
cat "$OUT/SHA256SUMS.txt"
ls -l "$OUT"
