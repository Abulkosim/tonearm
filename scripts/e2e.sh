#!/usr/bin/env bash
# End-to-end test of Tonearm's AppleScript path against a fake Spotify.
#
#   scripts/e2e.sh
#
# Builds the fake (Tools/FakeSpotify), a scriptable app with bundle id com.spotify.client,
# registers it with Launch Services, and runs `Tonearm --e2e` against it. The report and the
# fake's command log end up in $E2E_DIR/report. Exits non-zero if any check failed.
#
# On GitHub Actions it first allows Apple Events to the fake by writing rows into the user
# TCC database, which works there because SIP is off. Anywhere else macOS asks for
# Automation access the first time.
#
# Don't run this on a Mac where the real Spotify is installed: Launch Services may pick
# either app. Tonearm --e2e refuses to drive an app that is not the fake.
#
# Environment:
#   TONEARM_APP  Tonearm.app to test. Default: build/Tonearm.app, built if missing.
#   E2E_DIR      Work and output directory. Default: build/e2e.
set -euo pipefail
cd "$(dirname "$0")/.."

E2E_DIR="${E2E_DIR:-build/e2e}"
TONEARM_APP="${TONEARM_APP:-build/Tonearm.app}"
FAKE="$E2E_DIR/Spotify.app"
REPORT="$E2E_DIR/report"
FAKE_LOG="$HOME/Library/Logs/TonearmE2E/fake-spotify.log"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

# Runs a command, killing it after $1 seconds. macOS has no timeout(1).
with_timeout() {
  local seconds="$1"; shift
  perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"
}

build_fake() {
  rm -rf "$FAKE"
  mkdir -p "$FAKE/Contents/MacOS" "$FAKE/Contents/Resources"
  swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos13.0" \
    -o "$FAKE/Contents/MacOS/Spotify" Tools/FakeSpotify/main.swift
  cp Tools/FakeSpotify/Info.plist "$FAKE/Contents/Info.plist"
  cp Tools/FakeSpotify/Spotify.sdef "$FAKE/Contents/Resources/Spotify.sdef"
  codesign --force --sign - "$FAKE"
  "$LSREGISTER" -f "$FAKE"
}

quit_fake() {
  pkill -x Spotify 2>/dev/null || true
  for _ in $(seq 1 50); do
    pgrep -x Spotify > /dev/null || return 0
    sleep 0.1
  done
  pkill -9 -x Spotify 2>/dev/null || true
}

# Called by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  quit_fake
  "$LSREGISTER" -u "$FAKE" 2>/dev/null || true
}

# Lets these clients send Apple Events to com.spotify.client: osascript, bash, and the
# runner's agent, which macOS holds responsible for every process a job starts.
# Must run before anything sends an event: an event that already waits for consent is
# not released by a later grant.
allow_apple_events() {
  local db="$HOME/Library/Application Support/com.apple.TCC/TCC.db" client
  for client in /usr/bin/osascript /bin/bash /opt/hca/hosted-compute-agent \
                /usr/local/opt/runner/provisioner/provisioner; do
    sudo sqlite3 "$db" "insert or replace into access
      (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id,
       indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity,
       flags, last_modified)
      values ('kTCCServiceAppleEvents', '$client', 1, 2, 3, 1, NULL, NULL,
       0, 'com.spotify.client', NULL, 0, cast(strftime('%s','now') as integer));"
  done
  # tccd caches decisions.
  sudo killall tccd 2>/dev/null || true
  sleep 1
  echo "Apple Events to com.spotify.client allowed in the user TCC database"
}

# One read with osascript, outside Tonearm. If this fails, Apple Events don't get through.
preflight() {
  open -g "$FAKE"
  for _ in $(seq 1 50); do
    pgrep -x Spotify > /dev/null && break
    sleep 0.1
  done
  local reply
  if ! reply="$(with_timeout 30 osascript -e \
      'tell application id "com.spotify.client" to return (player state as string) & " / " & (name of current track)')"; then
    echo "preflight: osascript could not read the fake; Apple Events are blocked" >&2
    return 1
  fi
  echo "preflight: osascript read \"$reply\""
  quit_fake
}

[ -d "$TONEARM_APP" ] || scripts/build-app.sh
mkdir -p "$E2E_DIR"
rm -rf "$REPORT"
mkdir -p "$REPORT" "$(dirname "$FAKE_LOG")"
quit_fake
build_fake
trap cleanup EXIT
: > "$FAKE_LOG"
if [ "${GITHUB_ACTIONS:-}" = true ]; then
  allow_apple_events
fi
preflight

status=0
with_timeout 360 "$TONEARM_APP/Contents/MacOS/Tonearm" --e2e "$REPORT" || status=$?
cp "$FAKE_LOG" "$REPORT/fake-spotify.log"
echo "report: $REPORT/report.txt, exit $status"
exit "$status"
