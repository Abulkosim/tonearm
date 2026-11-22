#!/usr/bin/env bash
# Turns warnings in build logs into GitHub annotations and a job summary line, and fails
# when there is at least one. It counts:
#   - compiler warnings with a location (/path/File.swift:12:5: warning: ...), in the app
#     and in the tests, so pass the `swift test` log as well as the app build log;
#   - linker warnings (ld: warning: ...).
# Warnings about Sparkle's prebuilt binaries ("not stripping binary because it is signed")
# have no location and are not ld's, so they are not counted.
#
# Usage: scripts/swift-warnings.sh <build log>...
set -euo pipefail

[ "$#" -gt 0 ] || { echo "usage: swift-warnings.sh <build log>..." >&2; exit 2; }
for log in "$@"; do
  [ -s "$log" ] || { echo "::error::swift-warnings: $log is missing or empty" >&2; exit 1; }
done
root="${GITHUB_WORKSPACE:-$PWD}/"
# A universal build compiles each file twice, and the tests compile the app again, so the
# same warning can appear more than once.
compiler="$(cat "$@" | grep -E '^/[^:]+:[0-9]+:[0-9]+: warning: ' | sort -u || true)"
linker="$(cat "$@" | grep -oE 'ld: warning: .*' | sort -u || true)"
count=0
if [ -n "$compiler" ]; then
  while IFS= read -r line; do
    location="${line%%: warning: *}"
    message="${line#*: warning: }"
    col="${location##*:}"; location="${location%:*}"
    row="${location##*:}"; file="${location%:*}"
    echo "::warning file=${file#"$root"},line=$row,col=$col::$message"
    count=$((count + 1))
  done <<< "$compiler"
fi
if [ -n "$linker" ]; then
  while IFS= read -r line; do
    echo "::warning::$line"
    count=$((count + 1))
  done <<< "$linker"
fi
echo "Swift and linker warnings: $count"
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  echo "Swift and linker warnings: $count" >> "$GITHUB_STEP_SUMMARY"
fi
# main builds with none; keep it that way.
if [ "$count" -gt 0 ]; then
  echo "::error::$count warning(s); fix them"
  exit 1
fi
