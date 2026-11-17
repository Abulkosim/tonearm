#!/usr/bin/env bash
# Opens the real Liner Notes window in the running app, with a Spotify export as the
# runner's own history, and checks two things:
#   1. a plain launch opens no window by itself (SwiftUI may open a Window scene at launch);
#   2. --open-liner-notes opens one.
# Screenshots of both go to <out dir>. Window sizes come from CGWindowList, which needs no
# permission.
#
# Like live-launch.sh, it turns Sparkle's automatic checks off for the launches, so a build
# older than the latest release can't replace itself, and fails if the bundle changed.
#
# CI only: it writes the runner's Tonearm history and settings, and kills Tonearm.
# Usage: scripts/liner-notes-live.sh <Tonearm.app> <export dir or .zip> <out dir>
set -euo pipefail

app="${1:?usage: liner-notes-live.sh <Tonearm.app> <export> <out dir>}"
export_path="${2:?usage: liner-notes-live.sh <Tonearm.app> <export> <out dir>}"
out="${3:?usage: liner-notes-live.sh <Tonearm.app> <export> <out dir>}"
[ "${CI:-}" = true ] || { echo "liner-notes-live: CI only; it replaces Tonearm's history" >&2; exit 1; }
bundle_id=io.github.abulkosim.tonearm
bin="$app/Contents/MacOS/Tonearm"
db="$HOME/Library/Application Support/Tonearm/history.sqlite"
fail() { echo "::error::liner-notes-live: $*" >&2; exit 1; }
fingerprint() { shasum -a 256 < "$bin" | cut -d ' ' -f 1; }
# Tonearm's windows in the normal layer, as WIDTHxHEIGHT lines.
windows() {
  osascript -l JavaScript -e 'ObjC.import("CoreGraphics");
    const all = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
    all.filter(w => w.kCGWindowOwnerName === "Tonearm" && w.kCGWindowLayer === 0)
       .map(w => w.kCGWindowBounds.Width + "x" + w.kCGWindowBounds.Height).join("\n")'
}

mkdir -p "$out"
before="$(fingerprint)"
defaults write "$bundle_id" SUEnableAutomaticChecks -bool false
cleanup() {
  pkill -x Tonearm > /dev/null 2>&1 || true
  defaults delete "$bundle_id" SUEnableAutomaticChecks > /dev/null 2>&1 || true
  rm -f "$db" "$db-wal" "$db-shm"
}
trap cleanup EXIT

"$bin" --stats "$export_path" --db "$db" > /dev/null

open -n "$app"
sleep 8
plain="$(windows)"
echo "Windows at a plain launch: ${plain:-none}"
screencapture -x "$out/live-launch.png" || echo "::warning::screencapture failed"
pkill -x Tonearm || true
sleep 2

open -n "$app" --args --open-liner-notes
sleep 10
opened="$(windows)"
echo "Windows with --open-liner-notes: ${opened:-none}"
screencapture -x "$out/live-window.png" || echo "::warning::screencapture failed"
pgrep -x Tonearm > /dev/null || fail "Tonearm exited with the Liner Notes window open"
pkill -x Tonearm || true

[ "$(fingerprint)" = "$before" ] || fail "the bundle changed during the launches"
[ -z "$plain" ] || fail "a window opened by itself at launch: $plain"
[ -n "$opened" ] || fail "--open-liner-notes opened no window"
echo "liner-notes-live: no window at launch; the window opened at $opened"
