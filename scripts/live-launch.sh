#!/usr/bin/env bash
# Opens Tonearm.app the way a user does and checks it is still running 10 s later.
# This starts Sparkle, which the --snapshot runs never do.
#
# Sparkle's automatic checks are turned off for the launch, in user defaults, which Sparkle
# reads before Info.plist. With them on, a build older than the latest release would download
# that release from the real feed and replace itself in place (update-e2e.sh shows this takes
# about 5 s), and the steps after this one would test the published app instead. The script
# also fails if the bundle changed during the launch.
#
# CI only: it changes Tonearm's user defaults and kills Tonearm.
# Usage: scripts/live-launch.sh <Tonearm.app>
set -euo pipefail

app="${1:?usage: live-launch.sh <Tonearm.app>}"
[ "${CI:-}" = true ] || { echo "live-launch: CI only; it kills Tonearm and changes its settings" >&2; exit 1; }
bundle_id=io.github.abulkosim.tonearm
bin="$app/Contents/MacOS/Tonearm"
fail() { echo "::error::live-launch: $*" >&2; exit 1; }
fingerprint() {
  printf '%s %s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" \
    "$(shasum -a 256 < "$bin" | cut -d ' ' -f 1)"
}

before="$(fingerprint)"
defaults write "$bundle_id" SUEnableAutomaticChecks -bool false
restore() { defaults delete "$bundle_id" SUEnableAutomaticChecks > /dev/null 2>&1 || true; }
trap restore EXIT

start="$(date '+%Y-%m-%d %H:%M:%S')"
open -n "$app"
sleep 10
pgrep -x Tonearm > /dev/null || fail "Tonearm exited during the live launch"
pkill -x Tonearm || true
log show --start "$start" --style compact \
  --predicate 'process == "Tonearm" AND (subsystem BEGINSWITH "org.sparkle-project" OR eventMessage CONTAINS[c] "sparkle")' \
  | tail -n 40 || true

after="$(fingerprint)"
[ "$after" = "$before" ] || fail "the bundle changed during the launch (build and binary hash $before, now $after)"
echo "live-launch: Tonearm ran 10 s; bundle unchanged (build ${before%% *})"
