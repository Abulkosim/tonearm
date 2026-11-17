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
# It refuses to start while Spotify or Tonearm is running, and only ever quits the fake.
# Don't run it on a Mac where the real Spotify is installed: Launch Services may pick
# either app. Tonearm --e2e refuses to drive an app that is not the fake.
#
# Environment:
#   TONEARM_APP  Tonearm.app to test, as is. Default: build it with scripts/build-app.sh
#                and test build/Tonearm.app.
#   E2E_DIR      Work and output directory. Default: build/e2e.
set -euo pipefail
cd "$(dirname "$0")/.."

E2E_DIR="${E2E_DIR:-build/e2e}"
mkdir -p "$E2E_DIR"
FAKE="$(cd "$E2E_DIR" && pwd -P)/Spotify.app"
FAKE_EXE="$FAKE/Contents/MacOS/Spotify"
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

# Prints the pids of processes named Spotify: with "fake" those that run the fake's
# executable, with "other" the rest.
spotify_pids() {
  local pid exe
  for pid in $(pgrep -x Spotify || true); do
    exe="$(ps -o comm= -p "$pid" 2>/dev/null)" || continue
    if [ "$exe" = "$FAKE_EXE" ]; then
      [ "$1" = fake ] && echo "$pid"
    else
      [ "$1" = other ] && echo "$pid"
    fi
  done
  return 0
}

# Quits the fake, and nothing else. Fails if it is still running after 5 s and a SIGKILL.
quit_fake() {
  local pids
  pids="$(spotify_pids fake)"
  [ -n "$pids" ] || return 0
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  for _ in $(seq 1 50); do
    [ -z "$(spotify_pids fake)" ] && return 0
    sleep 0.1
  done
  pids="$(spotify_pids fake)"
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill -9 $pids 2>/dev/null || true
  sleep 0.5
  if [ -n "$(spotify_pids fake)" ]; then
    echo "e2e: the fake Spotify did not quit" >&2
    return 1
  fi
}

# A running Spotify would answer the test's Apple Events, and a running Tonearm would react
# to the fake's notifications and send its own commands.
refuse_if_running() {
  if [ -n "$(spotify_pids other)" ]; then
    echo "e2e: Spotify is running. Quit it first; this test only drives its fake." >&2
    exit 1
  fi
  if pgrep -x Tonearm > /dev/null; then
    echo "e2e: Tonearm is running. Quit it first; it would send its own commands to the fake." >&2
    exit 1
  fi
}

# Called by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  quit_fake || true
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
    [ -n "$(spotify_pids fake)" ] && break
    sleep 0.1
  done
  if [ -z "$(spotify_pids fake)" ]; then
    echo "preflight: the fake did not start, or runs from a path other than $FAKE_EXE" >&2
    return 1
  fi
  local reply
  if ! reply="$(with_timeout 30 osascript -e \
      'tell application id "com.spotify.client" to return (player state as string) & " / " & (name of current track)')"; then
    echo "preflight: osascript could not read the fake; Apple Events are blocked" >&2
    return 1
  fi
  echo "preflight: osascript read \"$reply\""
  quit_fake
}

refuse_if_running
if [ -z "${TONEARM_APP:-}" ]; then
  scripts/build-app.sh
  TONEARM_APP=build/Tonearm.app
fi
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
