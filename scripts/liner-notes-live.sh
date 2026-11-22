#!/usr/bin/env bash
# Opens the real Liner Notes window in the running app, with a Spotify export as the
# runner's own history, and checks:
#   1. a plain launch shows no window, looking every half second for 8 s (SwiftUI may open
#      a Window scene at launch, and Tonearm closes it);
#   2. --open-liner-notes opens the Liner Notes window itself: the app logs the window's
#      number, and that number must be on screen;
#   3. the player's window tracking would not take any Liner Notes window for its popover,
#      including one SwiftUI opened at launch. The app logs that per window;
#   4. the window comes to the front, though Tonearm is a menu bar app (LSUIElement), which
#      macOS does not bring forward by itself: the Liner Notes window is the frontmost
#      window on screen. Which app is active is reported, not checked (see below).
# Screenshots and the app's logs go to <out dir>. Windows come from CGWindowList, which
# needs no permission. The app logs with --log-windows (and --open-liner-notes).
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
# Tonearm's windows in the normal layer, as "NUMBER WIDTHxHEIGHT" lines.
windows() {
  osascript -l JavaScript -e 'ObjC.import("CoreGraphics");
    const all = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
    all.filter(w => w.kCGWindowOwnerName === "Tonearm" && w.kCGWindowLayer === 0)
       .map(w => w.kCGWindowNumber + " " + w.kCGWindowBounds.Width + "x" + w.kCGWindowBounds.Height).join("\n")'
}

# The frontmost app, and the frontmost normal window on screen as "OWNER NUMBER". Window
# lists come front to back.
front_app() {
  osascript -l JavaScript -e 'ObjC.import("AppKit"); $.NSWorkspace.sharedWorkspace.frontmostApplication.localizedName.js'
}
front_window() {
  osascript -l JavaScript -e 'ObjC.import("CoreGraphics");
    const all = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
    const w = all.find(w => w.kCGWindowLayer === 0);
    w ? w.kCGWindowOwnerName + " " + w.kCGWindowNumber : "none"'
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

# 1. A plain launch. --log-windows changes nothing but the log.
launch_log="$out/live-launch.log"
: > "$launch_log"
open -n --stderr "$launch_log" "$app" --args --log-windows
seen=""
for _ in $(seq 16); do
  sleep 0.5
  now="$(windows)"
  if [ -n "$now" ]; then seen="$seen$now"$'\n'; fi
done
echo "Windows at a plain launch, any time in 8 s: ${seen:-none}"
screencapture -x "$out/live-launch.png" || echo "::warning::screencapture failed"
pkill -x Tonearm || true
sleep 2
launch_lines="$(grep '^liner-notes-window:' "$launch_log" || true)"
echo "Liner Notes windows the app saw at a plain launch: ${launch_lines:-none}"

# 2. --open-liner-notes.
window_log="$out/live-window.log"
: > "$window_log"
open -n --stderr "$window_log" "$app" --args --open-liner-notes
opened_line=""
for _ in $(seq 20); do
  sleep 0.5
  opened_line="$(grep '^liner-notes-window: opened ' "$window_log" | tail -n 1 || true)"
  if [ -n "$opened_line" ]; then break; fi
done
sleep 3
opened="$(windows)"
front="$(front_app)"
front_win="$(front_window)"
echo "Windows with --open-liner-notes: ${opened:-none}"
echo "Frontmost app: $front; frontmost window: $front_win"
echo "The app's line: ${opened_line:-none}"
# How long the window took to show its first page, the store warmed at launch. Not gated.
first_page="$(grep '^liner-notes-window: first page' "$window_log" | tail -n 1 || true)"
echo "First page: ${first_page:-not logged}"
screencapture -x "$out/live-window.png" || echo "::warning::screencapture failed"
pgrep -x Tonearm > /dev/null || fail "Tonearm exited with the Liner Notes window open"
pkill -x Tonearm || true

[ "$(fingerprint)" = "$before" ] || fail "the bundle changed during the launches"
[ -z "$seen" ] || fail "a window showed at a plain launch: $seen"
[ -n "$opened_line" ] || fail "--open-liner-notes: the app never logged the Liner Notes window"
number="$(sed -E 's/.* number=([0-9]+) .*/\1/' <<< "$opened_line")"
identifier="$(sed -E 's/.* id=([^ ]+) .*/\1/' <<< "$opened_line")"
[[ "$identifier" == liner-notes* ]] || fail "the window's identifier is $identifier, not liner-notes-*"
grep -q "^$number " <<< "$opened" || fail "window $number, which the app opened, is not on screen: $opened"
# Reported, not gated: macOS 14 and later let an app take the front only when the user
# or the active app hands it over, and this window opens from a launch flag with nobody
# clicking. Opened from the player, Tonearm is already the active app.
[ "$front" = Tonearm ] || echo "::warning::liner-notes-live: $front, not Tonearm, is the active app"
[ "$front_win" = "Tonearm $number" ] || fail "the Liner Notes window ($number) is not in front; $front_win is"
all_lines="$(printf '%s\n%s\n' "$launch_lines" "$(grep '^liner-notes-window:' "$window_log")")"
if grep -q 'popover=yes' <<< "$all_lines"; then
  fail "the player would take a Liner Notes window for its popover: $all_lines"
fi
echo "liner-notes-live: no window at launch; window $number ($identifier) opened in front at" \
  "$(grep "^$number " <<< "$opened" | cut -d ' ' -f 2); the player's tracking skips it"
