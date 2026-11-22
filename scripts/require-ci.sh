#!/usr/bin/env bash
# Refuses a release unless the tagged commit is on main and every required check passed on
# that exact commit. release.yml runs it before it builds anything.
#
# release.yml builds, signs and publishes; it runs no tests, state walk, live E2E or Liner
# Notes checks of its own. Those ran in CI on the commit. But a tag can be pushed before CI
# on main finishes (v0.4.0's was, 28 s after CI started) or after it failed. So this waits
# for the checks, up to CI_WAIT_SECONDS, and fails if any of them did not pass.
#
# Only check runs made by GitHub Actions count, and for each name only the newest (a rerun
# replaces a failure). REQUIRED must list the required checks of main's branch protection.
#
# Usage: scripts/require-ci.sh <commit sha>
# Environment:
#   GH_TOKEN, GITHUB_REPOSITORY  the token needs contents: read and checks: read
#   CI_WAIT_SECONDS  how long to wait for checks to finish. Default 3600; 0 does not wait.
#   CI_RUNS_FILE     test only: read check runs from this file (the API's check_runs
#                    array) instead of GitHub, and skip the main branch check.
set -euo pipefail

REQUIRED=("Build and snapshot" "Self-signed build" "Scripts and release notes" "E2E with fake Spotify")

sha="${1:?usage: require-ci.sh <commit sha>}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "::error::require-ci: not a full commit sha: $sha" >&2; exit 1; }
wait_seconds="${CI_WAIT_SECONDS:-3600}"
poll=30
fail() { echo "::error::require-ci: $*" >&2; exit 1; }

if [ -z "${CI_RUNS_FILE:-}" ]; then
  repo="${GITHUB_REPOSITORY:?}"
  # compare/main...sha is "behind" or "identical" when sha is on main.
  where="$(gh api "repos/$repo/compare/main...$sha" --jq .status)"
  case "$where" in
    behind | identical) echo "require-ci: $sha is on main" ;;
    *) fail "$sha is not on main (compare says $where); tag a commit on main" ;;
  esac
fi

runs() {
  if [ -n "${CI_RUNS_FILE:-}" ]; then
    cat "$CI_RUNS_FILE"
  else
    gh api --paginate "repos/$repo/commits/$sha/check-runs?per_page=100" --jq '.check_runs[]' | jq -s .
  fi
}

# One line per required check: "<state> <name>", state ok, failed:<conclusion>, pending or missing.
states() {
  local required
  required="$(printf '%s\n' "${REQUIRED[@]}" | jq -R . | jq -s .)"
  runs | jq -r --argjson required "$required" '
    [.[] | select(.app.slug == "github-actions")] as $runs
    | $required[] as $name
    | ([$runs[] | select(.name == $name)] | sort_by(.started_at // "", .id) | last) as $run
    | if $run == null then "missing \($name)"
      elif $run.status != "completed" then "pending \($name)"
      elif $run.conclusion == "success" then "ok \($name)"
      else "failed:\($run.conclusion) \($name)" end'
}

deadline=$((SECONDS + wait_seconds))
while :; do
  report="$(states)"
  echo "$report"
  if grep -q '^failed' <<< "$report"; then
    fail "a required check did not pass on $sha: $(grep '^failed' <<< "$report" | tr '\n' ' ')"
  fi
  if ! grep -qvE '^ok ' <<< "$report"; then
    echo "require-ci: all ${#REQUIRED[@]} required checks passed on $sha"
    exit 0
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    fail "required checks not finished on $sha after ${wait_seconds} s: $(grep -v '^ok ' <<< "$report" | tr '\n' ' ')"
  fi
  echo "require-ci: waiting ${poll} s for checks to finish"
  sleep "$poll"
done
