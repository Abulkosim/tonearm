#!/usr/bin/env bash
# Measures what Tonearm costs while nobody looks at it, and fails over budget.
#
#   scripts/idle-cost.sh <Tonearm.app> [report dir]
#
# Runs the real app, player closed, for 60 s in each of three states: Spotify not running,
# Spotify paused, and Spotify playing. For each it records the CPU time and wakeups the
# kernel charged Tonearm (proc_pid_rusage, through Tools/IdleCost/rusage.swift), and how
# many times Tonearm read Spotify (the fake's log). A menu bar app should cost next to
# nothing here: no reads at all while paused, one every 30 s while playing.
#
# The CPU time is checked against `ps` too, so a wrong unit in the meter can't pass.
#
# Uses the fake Spotify that scripts/e2e.sh builds, so run that first, in the same job: it
# also lets the runner send Apple Events to the fake.
#
# CI only: it changes Tonearm's user defaults and kills Tonearm.
#
# Environment (budgets are per state, for the whole window):
#   IDLE_SECONDS         Length of each window. Default 60.
#   IDLE_CPU_MS          CPU budget in ms, "not running paused playing". Default below.
#   IDLE_WAKEUPS         Wakeup budget, same order.
#   IDLE_READS           Read budget, same order.
set -euo pipefail
cd "$(dirname "$0")/.."

app="${1:?usage: idle-cost.sh <Tonearm.app> [report dir]}"
out="${2:-build/e2e/report}"
[ "${CI:-}" = true ] || { echo "idle-cost: CI only; it kills Tonearm and changes its settings" >&2; exit 1; }

window="${IDLE_SECONDS:-60}"
# Two runs on macos-15 runners measured CPU 15 and 14, 2 and 5, 59 and 35 ms; wakeups 6 and
# 5, 4 and 5, 12 and 14; reads 0, 0 and 1. Polling 10x faster measured 339 ms, 104 wakeups
# and 20 reads while playing. The budgets sit between, with room for runner noise. Reads
# are exact: none while paused, one per 30 s while playing, so 60 s sees at most 3.
read -r -a cpu_budget <<< "${IDLE_CPU_MS:-100 100 200}"
read -r -a wakeup_budget <<< "${IDLE_WAKEUPS:-60 60 60}"
read -r -a read_budget <<< "${IDLE_READS:-0 0 3}"

E2E_DIR="${E2E_DIR:-build/e2e}"
FAKE="$(cd "$E2E_DIR" && pwd -P)/Spotify.app"
FAKE_EXE="$FAKE/Contents/MacOS/Spotify"
FAKE_LOG="$HOME/Library/Logs/TonearmE2E/fake-spotify.log"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
bundle_id=io.github.abulkosim.tonearm
work="$(mktemp -d)"
meter="$work/rusage"
report="$out/idle-cost.txt"
pid=""

fail() { echo "::error::idle-cost: $*" >&2; exit 1; }
[ -x "$FAKE_EXE" ] || fail "no fake Spotify at $FAKE; run scripts/e2e.sh first"
pgrep -x Tonearm > /dev/null && fail "Tonearm is running; quit it first"

fake_pids() {
  local p
  for p in $(pgrep -x Spotify || true); do
    [ "$(ps -o comm= -p "$p" 2>/dev/null)" = "$FAKE_EXE" ] && echo "$p"
  done
  return 0
}

quit_fake() {
  local pids
  pids="$(fake_pids)"
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill $pids 2>/dev/null || true
  for _ in $(seq 1 50); do
    [ -z "$(fake_pids)" ] && return 0
    sleep 0.1
  done
  pids="$(fake_pids)"
  # shellcheck disable=SC2086
  [ -z "$pids" ] || kill -9 $pids 2>/dev/null || true
}

# Called by the EXIT trap.
# shellcheck disable=SC2317
cleanup() {
  [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
  quit_fake
  "$LSREGISTER" -u "$FAKE" 2>/dev/null || true
  defaults delete "$bundle_id" SUEnableAutomaticChecks > /dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

log_size() { wc -c < "$FAKE_LOG" | tr -d ' '; }
# Lines the fake logged after byte offset $1 that end in $2.
count_since() { tail -c "+$(($1 + 1))" "$FAKE_LOG" | grep -c " $2\$" || true; }
wait_for_log() {
  local mark="$1" event="$2" seconds="$3"
  for _ in $(seq 1 $((seconds * 10))); do
    [ "$(count_since "$mark" "$event")" -gt 0 ] && return 0
    sleep 0.1
  done
  fail "the fake never logged \"$event\" within $seconds s"
}
field() { sed -n "s/.*$1=\([0-9]*\).*/\1/p" <<< "$2"; }
# CPU time from ps, in ms. ps prints [hh:]mm:ss.cc.
ps_cpu_ms() {
  ps -o time= -p "$1" | awk -F: '{ s = 0; for (i = 1; i <= NF; i++) s = s * 60 + $i; printf "%d\n", s * 1000 }'
}

swiftc -O -o "$meter" Tools/IdleCost/rusage.swift
mkdir -p "$out" "$(dirname "$FAKE_LOG")"
touch "$FAKE_LOG"
quit_fake
"$LSREGISTER" -f "$FAKE"
defaults write "$bundle_id" SUEnableAutomaticChecks -bool false
# No welcome window: the point is a closed player.
defaults write "$bundle_id" welcomeShown -bool true

: > "$report"
say() { echo "$*" | tee -a "$report"; }
failures=0
states=("not running" "paused" "playing")

# Measures the state with index $1 for $window seconds.
measure() {
  local i="$1" name="${states[$1]}" before after mark
  before="$("$meter" "$pid")"
  mark="$(log_size)"
  sleep "$window"
  kill -0 "$pid" 2>/dev/null || fail "Tonearm exited while measuring \"$name\""
  after="$("$meter" "$pid")"
  local cpu_ms=$((($(field cpu_ns "$after") - $(field cpu_ns "$before")) / 1000000))
  local idle=$(($(field idle_wakeups "$after") - $(field idle_wakeups "$before")))
  local irq=$(($(field interrupt_wakeups "$after") - $(field interrupt_wakeups "$before")))
  local wakeups=$((idle + irq))
  local reads
  reads="$(count_since "$mark" "get player state")"
  say "$name: cpu ${cpu_ms} ms (budget ${cpu_budget[$i]}), wakeups $wakeups (idle $idle, interrupt $irq; budget ${wakeup_budget[$i]}), reads $reads (budget ${read_budget[$i]}) in ${window} s"
  local over=""
  [ "$cpu_ms" -le "${cpu_budget[$i]}" ] || over="$over cpu"
  [ "$wakeups" -le "${wakeup_budget[$i]}" ] || over="$over wakeups"
  [ "$reads" -le "${read_budget[$i]}" ] || over="$over reads"
  if [ -n "$over" ]; then
    echo "::error::idle-cost: \"$name\" is over budget:$over"
    failures=$((failures + 1))
  fi
}

"$app/Contents/MacOS/Tonearm" > "$work/tonearm.log" 2>&1 &
pid=$!
sleep 15
measure 0
[ -z "$(fake_pids)" ] || fail "something launched Spotify while it was not running"

mark="$(log_size)"
open -g "$FAKE"
wait_for_log "$mark" "launched" 15
# Tonearm reads a starting Spotify until it answers, then stops: the fake starts paused.
wait_for_log "$mark" "get player state" 20
sleep 15
measure 1

mark="$(log_size)"
osascript -e 'tell application id "com.spotify.client" to play' > /dev/null
wait_for_log "$mark" "posted playing" 10
wait_for_log "$mark" "get player state" 10
sleep 5
measure 2

# The meter's CPU time against ps, over the whole run. Off by more than this means the
# meter reads the wrong unit (Mach ticks are 41.67 ns on Apple silicon) or the wrong process.
meter_ms=$(($(field cpu_ns "$("$meter" "$pid")") / 1000000))
ps_ms="$(ps_cpu_ms "$pid")"
say "total since launch: meter ${meter_ms} ms, ps ${ps_ms} ms"
diff=$((meter_ms > ps_ms ? meter_ms - ps_ms : ps_ms - meter_ms))
[ "$diff" -le $((50 + ps_ms / 5)) ] || fail "the meter and ps disagree: ${meter_ms} ms against ${ps_ms} ms"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  { echo '```'; cat "$report"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"
fi
[ "$failures" -eq 0 ] || fail "$failures state(s) over budget; see $report"
echo "idle-cost: every state within budget"
