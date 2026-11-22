#!/usr/bin/env bash
# Checks that a running Tonearm's main thread keeps answering, not only that the process
# exists: an app whose main thread hangs stays up and shows a spinning cursor.
#
# Once a second, Tools/LaunchPing sends the app an Apple Event it has no handler for. AppKit
# answers that on the main thread with "not handled", so an answer proves the main thread is
# running its run loop. No answer within 5 s, or the process exiting, fails.
#
#   scripts/ping-app.sh prepare           Build the tool and, on GitHub Actions, let it send
#                                         Apple Events to Tonearm. Run it before Tonearm starts:
#                                         an event that waits for consent is not released later.
#   scripts/ping-app.sh <pid> [seconds]   Ping for that long, default 10, and print the slowest answer.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
bundle_id=io.github.abulkosim.tonearm
src="$repo/Tools/LaunchPing/main.swift"
tool="${TMPDIR:-/tmp}/tonearm-launch-ping-$(shasum -a 256 < "$src" | cut -c 1-16)"
fail() { echo "::error::ping-app: $*" >&2; exit 1; }

if [ "${1:-}" = prepare ]; then
  if [ ! -x "$tool" ]; then
    swiftc -O -o "$tool.tmp" "$src"
    mv "$tool.tmp" "$tool"
  fi
  if [ "${GITHUB_ACTIONS:-}" = true ]; then
    "$repo/scripts/allow-apple-events.sh" "$bundle_id" "$tool"
  fi
  exit 0
fi

pid="${1:?usage: ping-app.sh prepare | ping-app.sh <pid> [seconds]}"
seconds="${2:-10}"
[[ "$pid" =~ ^[0-9]+$ && "$seconds" =~ ^[0-9]+$ ]] || fail "usage: ping-app.sh <pid> [seconds]"
[ -x "$tool" ] || fail "run scripts/ping-app.sh prepare first"

pings=0
slowest=0
end=$((SECONDS + seconds))
while [ "$SECONDS" -lt "$end" ]; do
  kill -0 "$pid" 2> /dev/null || fail "pid $pid exited, after $pings answered pings"
  if ! answer="$("$tool" "$pid" 5 2>&1)"; then
    kill -0 "$pid" 2> /dev/null || fail "pid $pid exited, after $pings answered pings"
    fail "$answer"
  fi
  ms="${answer#ok }"
  ms="${ms%% *}"
  ms="${ms%.*}"
  pings=$((pings + 1))
  [ "$ms" -le "$slowest" ] || slowest="$ms"
  sleep 1
done
[ "$pings" -gt 0 ] || fail "no pings sent"
echo "pid $pid answered $pings pings in ${seconds} s, slowest ${slowest} ms"
