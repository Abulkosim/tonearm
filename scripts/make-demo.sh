#!/usr/bin/env bash
# Renders every picture of Tonearm in the README and on the website, from the app's own
# views with a made-up listening history: the animation demo.gif and the stills
# player.png, compact.png, liner-notes.png, share-card.png and social.png.
#
#   scripts/make-demo.sh [out dir]          default: docs/images
#   scripts/make-demo.sh --check [out dir]  also fails if docs/images differs from the render
#
# The numbers in the pictures come from the app's import and stats code; build/demo-frames/
# report.txt lists them.
#
# Needs a built app (scripts/build-app.sh) and gifski (brew install gifski).
set -euo pipefail
cd "$(dirname "$0")/.."

check=()
if [[ "${1:-}" == "--check" ]]; then
  check=(--compare docs/images)
  shift
fi
out="${1:-docs/images}"
app="build/Tonearm.app/Contents/MacOS/Tonearm"
frames="build/demo-frames"

[[ -x "$app" ]] || { echo "make-demo: build the app first: scripts/build-app.sh" >&2; exit 1; }
command -v gifski > /dev/null || { echo "make-demo: install gifski: brew install gifski" >&2; exit 1; }

rm -rf "$frames"
mkdir -p "$out"
# With --check, the app exits 1 after writing everything when a still differs.
status=0
"$app" --demo "$frames" ${check[@]+"${check[@]}"} || status=$?
[[ -f "$frames/report.txt" ]] || { echo "make-demo: the app wrote no report (exit $status)" >&2; exit 1; }
# 10 fps matches Snapshot.demoFPS. 1520 px is twice the README's 760 px width, so it is
# sharp on a Retina screen.
gifski --fps 10 --quality 90 --width 1520 --output "$out/demo.gif" "$frames"/frame-*.png
for still in player.png compact.png liner-notes.png share-card.png social.png; do
  cp "$frames/$still" "$out/$still"
done
ls -l "$out"
exit "$status"
