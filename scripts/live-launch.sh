#!/usr/bin/env bash
# Opens Tonearm.app the way a user does and, for 10 s, checks once a second that it is still
# running and that its main thread answers. This starts Sparkle, which the --snapshot runs
# never do.
#
# A process that exists proves little: an app whose main thread hangs at launch stays up and
# shows a spinning cursor. So each second Tools/LaunchPing sends Tonearm an Apple Event it has
# no handler for. AppKit answers that on the main thread with "not handled"; a hung main
# thread does not answer within 5 s, and the launch fails. The script prints the slowest
# answer.
#
# Sparkle's automatic checks are turned off for the launch, in user defaults, which Sparkle
# reads before Info.plist. With them on, a build older than the latest release would download
# that release from the real feed and replace itself in place (update-e2e.sh shows this takes
# about 5 s), and the steps after this one would test the published app instead. The script
# also fails if the bundle changed during the launch.
#
# CI only: it changes Tonearm's user defaults and the TCC database, and kills Tonearm.
# Usage: scripts/live-launch.sh <Tonearm.app>
set -euo pipefail

app="${1:?usage: live-launch.sh <Tonearm.app>}"
[ "${CI:-}" = true ] || { echo "live-launch: CI only; it kills Tonearm and changes its settings" >&2; exit 1; }
app="$(cd "$app" && pwd -P)"
repo="$(cd "$(dirname "$0")/.." && pwd)"
bundle_id=io.github.abulkosim.tonearm
bin="$app/Contents/MacOS/Tonearm"
seconds=10
fail() { echo "::error::live-launch: $*" >&2; exit 1; }
fingerprint() {
  printf '%s %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" \
    "$(shasum -a 256 < "$bin" | cut -d ' ' -f 1)"
}

pgrep -x Tonearm > /dev/null && fail "Tonearm is already running; quit it first"
before="$(fingerprint)"
work="$(mktemp -d)"
pid=""
# Called by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  [ -z "$pid" ] || kill "$pid" 2> /dev/null || true
  defaults delete "$bundle_id" SUEnableAutomaticChecks > /dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

ping="$work/ping"
swiftc -O -o "$ping" "$repo/Tools/LaunchPing/main.swift"
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  "$repo/scripts/allow-apple-events.sh" "$bundle_id" "$ping"
fi
defaults write "$bundle_id" SUEnableAutomaticChecks -bool false

start="$(date '+%Y-%m-%d %H:%M:%S')"
open -n "$app"
for _ in $(seq 1 100); do
  pid="$(pgrep -nx Tonearm || true)"
  [ -n "$pid" ] && break
  sleep 0.1
done
[ -n "$pid" ] || fail "Tonearm did not start within 10 s"
running="$(ps -o comm= -p "$pid" || true)"
[ "$running" = "$bin" ] || fail "the Tonearm that started is $running, not $bin"

pings=0
slowest=0
end=$((SECONDS + seconds))
while [ "$SECONDS" -lt "$end" ]; do
  kill -0 "$pid" 2> /dev/null || fail "Tonearm exited during the live launch, after $pings answered pings"
  if ! answer="$("$ping" "$pid" 5 2>&1)"; then
    kill -0 "$pid" 2> /dev/null || fail "Tonearm exited during the live launch, after $pings answered pings"
    fail "$answer"
  fi
  ms="${answer#ok }"
  ms="${ms%% *}"
  ms="${ms%.*}"
  pings=$((pings + 1))
  [ "$ms" -le "$slowest" ] || slowest="$ms"
  sleep 1
done
kill "$pid" 2> /dev/null || true
pid=""
log show --start "$start" --style compact \
  --predicate 'process == "Tonearm" AND (subsystem BEGINSWITH "org.sparkle-project" OR eventMessage CONTAINS[c] "sparkle")' \
  | tail -n 40 || true

after="$(fingerprint)"
[ "$after" = "$before" ] || fail "the bundle changed during the launch (build and binary hash $before, now $after)"
summary="Tonearm ran ${seconds} s; its main thread answered $pings pings, slowest ${slowest} ms; bundle unchanged (build ${before%% *})"
echo "live-launch: $summary"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Live launch: $summary" >> "$GITHUB_STEP_SUMMARY"
fi
