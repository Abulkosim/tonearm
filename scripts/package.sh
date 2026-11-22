#!/usr/bin/env bash
# Packages build/Tonearm.app (from scripts/build-app.sh) into dist/:
#   Tonearm-<version>.zip   the Sparkle update archive
#   Tonearm-<version>.dmg
#   Tonearm.zip, Tonearm.dmg  identical copies with stable names, so
#                             releases/latest/download/Tonearm.dmg always works
#   SHA256SUMS.txt
#
# Environment:
#   VERSION        File name version. Default: CFBundleShortVersionString of the built app.
#   SIGN_IDENTITY  A Developer ID identity signs the dmg. Ad-hoc ("-", the default) and
#                  self-signed builds leave it unsigned; Gatekeeper ignores those signatures.
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

developer_id=false
case "$SIGN_IDENTITY" in "Developer ID Application:"*) developer_id=true ;; esac
if [ "$NOTARIZE" = true ] && [ "$developer_id" != true ]; then
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

# hdiutil has failed on GitHub's runners with "create failed - Resource busy", and 40 ms
# after a create with "verify failed - Resource temporarily unavailable" (CI runs
# 44190267916 and 44192171935). Both mean another process had the image open: macOS scans
# and indexes new disk images in the background (actions/runner-images#7522). So the image
# is made in a folder Spotlight skips (.noindex) and moved to dist/ only once it verifies,
# and every hdiutil call first waits until no process has the image open. If a call still
# fails, the warning names the processes that had it open, and it is tried again.
holders() { lsof -F c -- "$1" 2> /dev/null | sed -n 's/^c//p' | sort -u | paste -s -d ' ' - || true; }
wait_unused() {
  local who=""
  [ -e "$1" ] || return 0
  for _ in $(seq 1 60); do
    who="$(holders "$1")"
    [ -z "$who" ] && return 0
    sleep 0.5
  done
  echo "::warning::package: $1 still open after 30 s, in: $who"
}
# hdi <image> <hdiutil arguments...>
hdi() {
  local image="$1" attempt
  shift
  for attempt in 1 2 3; do
    wait_unused "$image"
    if hdiutil "$@"; then
      return 0
    fi
    echo "::warning::package: hdiutil $1 failed (attempt $attempt of 3); open in: $(holders "$image")"
    [ "$attempt" -lt 3 ] || return 1
    sleep 5
  done
}

mkdir "$work/dmg" "$work/image.noindex"
ditto "$APP" "$work/dmg/Tonearm.app"
ln -s /Applications "$work/dmg/Applications"
image="$work/image.noindex/$(basename "$DMG")"
hdi "$image" create -volname Tonearm -srcfolder "$work/dmg" -ov -format UDZO "$image"

if [ "$developer_id" = true ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$image"
  codesign --verify --verbose=2 "$image"
fi
if [ "$NOTARIZE" = true ]; then
  scripts/notarize.sh "$image"
  xcrun stapler staple "$image"
  spctl -a -t open --context context:primary-signature -vv "$image"
fi
hdi "$image" verify "$image"
mv "$image" "$DMG"

cp "$ZIP" "$OUT/Tonearm.zip"
cp "$DMG" "$OUT/Tonearm.dmg"
(cd "$OUT" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" Tonearm.zip Tonearm.dmg > SHA256SUMS.txt)
cat "$OUT/SHA256SUMS.txt"
ls -l "$OUT"
