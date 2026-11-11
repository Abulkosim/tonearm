#!/usr/bin/env bash
# Renders the README animation from the app's own views with sample songs.
#
#   scripts/make-demo.sh [out.gif]     default: docs/images/demo.gif
#
# Needs a built app (scripts/build-app.sh) and gifski (brew install gifski).
set -euo pipefail
cd "$(dirname "$0")/.."

out="${1:-docs/images/demo.gif}"
app="build/Tonearm.app/Contents/MacOS/Tonearm"
frames="build/demo-frames"

[[ -x "$app" ]] || { echo "make-demo: build the app first: scripts/build-app.sh" >&2; exit 1; }
command -v gifski > /dev/null || { echo "make-demo: install gifski: brew install gifski" >&2; exit 1; }

rm -rf "$frames"
"$app" --demo "$frames"
# 10 fps matches Snapshot.demoFPS. 824 px is the 2x render of the 412 pt frame.
gifski --fps 10 --quality 90 --width 824 --output "$out" "$frames"/frame-*.png
ls -l "$out"
