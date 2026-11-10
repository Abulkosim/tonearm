#!/usr/bin/env bash
# Turns compiler warnings in a build log into GitHub annotations and a job summary line.
# Usage: scripts/swift-warnings.sh build/build.log
set -euo pipefail

log="${1:?usage: swift-warnings.sh <build log>}"
root="${GITHUB_WORKSPACE:-$PWD}/"
# A universal build compiles each file twice, so the same warning appears twice.
warnings="$(grep -E '^/[^:]+:[0-9]+:[0-9]+: warning: ' "$log" | sort -u || true)"
count=0
if [ -n "$warnings" ]; then
  count="$(printf '%s\n' "$warnings" | wc -l | tr -d ' ')"
  while IFS= read -r line; do
    location="${line%%: warning: *}"
    message="${line#*: warning: }"
    col="${location##*:}"; location="${location%:*}"
    row="${location##*:}"; file="${location%:*}"
    echo "::warning file=${file#"$root"},line=$row,col=$col::$message"
  done <<< "$warnings"
fi
echo "Swift warnings: $count"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Swift warnings: $count" >> "$GITHUB_STEP_SUMMARY"
fi
