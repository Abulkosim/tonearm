#!/usr/bin/env bash
# Tests scripts/require-ci.sh offline, on made-up check runs: it must pass only when every
# required check's newest GitHub Actions run succeeded. CI runs this on every pull request.
# Usage: scripts/require-ci-test.sh
set -euo pipefail
cd "$(dirname "$0")/.."

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
sha=0123456789abcdef0123456789abcdef01234567
failures=0

# run <name> [status conclusion started_at app]: one check run as JSON.
run() {
  jq -n --arg name "$1" --arg status "${2:-completed}" --arg conclusion "${3:-success}" \
    --arg started "${4:-2026-01-01T00:00:00Z}" --arg app "${5:-github-actions}" \
    '{name: $name, status: $status, conclusion: (if $status == "completed" then $conclusion else null end),
      started_at: $started, id: 1, app: {slug: $app}}'
}
green() {
  run "Build and snapshot"; run "Self-signed build"; run "Scripts and release notes"
  run "E2E with fake Spotify"
}
# expect <pass|fail> <case> < runs as JSON objects
expect() {
  local want="$1" name="$2" got=pass
  jq -s . > "$work/runs.json"
  CI_RUNS_FILE="$work/runs.json" CI_WAIT_SECONDS=0 scripts/require-ci.sh "$sha" > "$work/out" 2>&1 || got=fail
  if [ "$got" = "$want" ]; then
    echo "ok: $name ($got)"
  else
    echo "FAIL: $name: expected $want, got $got"
    sed 's/^/  /' "$work/out"
    failures=$((failures + 1))
  fi
}

green | expect pass "all required checks passed"
{ green; run "Fake matches Spotify's dictionary" completed failure; } | expect pass "a check that is not required failed"
{ green | jq -c 'select(.name != "E2E with fake Spotify")'; } | expect fail "a required check is missing"
{ green | jq -c 'select(.name != "Self-signed build")'; run "Self-signed build" completed failure; } \
  | expect fail "a required check failed"
{ green | jq -c 'select(.name != "Self-signed build")'; run "Self-signed build" completed cancelled; } \
  | expect fail "a required check was cancelled"
{ green | jq -c 'select(.name != "E2E with fake Spotify")'; run "E2E with fake Spotify" completed skipped; } \
  | expect fail "a required check was skipped"
{ green | jq -c 'select(.name != "Build and snapshot")'; run "Build and snapshot" in_progress; } \
  | expect fail "a required check is still running, no time to wait"
{ green | jq -c 'select(.name != "Build and snapshot")'
  run "Build and snapshot" completed failure 2026-01-01T00:00:00Z
  run "Build and snapshot" completed success 2026-01-01T01:00:00Z; } | expect pass "a rerun passed after a failure"
{ green | jq -c 'select(.name != "Build and snapshot")'
  run "Build and snapshot" completed success 2026-01-01T00:00:00Z
  run "Build and snapshot" completed failure 2026-01-01T01:00:00Z; } | expect fail "a rerun failed after a pass"
{ green | jq -c 'select(.name != "Build and snapshot")'
  run "Build and snapshot" completed success 2026-01-01T00:00:00Z some-other-app; } \
  | expect fail "only another app reported the check"
if CI_RUNS_FILE=/dev/null CI_WAIT_SECONDS=0 scripts/require-ci.sh not-a-sha > /dev/null 2>&1; then
  echo "FAIL: accepted a commit that is not a full sha"; failures=$((failures + 1))
else
  echo "ok: refuses a commit that is not a full sha"
fi

[ "$failures" -eq 0 ] || { echo "::error::require-ci-test: $failures case(s) failed"; exit 1; }
echo "require-ci-test: all cases passed"
