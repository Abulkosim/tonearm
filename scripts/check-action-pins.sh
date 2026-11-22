#!/usr/bin/env bash
# Fails if a workflow uses an action by a tag or branch instead of a full commit SHA.
# A tag can be moved to other code; a SHA can't. Local actions (./...) are fine.
# Usage: scripts/check-action-pins.sh [workflow files...]   Default: .github/workflows/*.yml
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$#" -gt 0 ] || set -- .github/workflows/*.yml .github/workflows/*.yaml
bad=0
count=0
for file in "$@"; do
  [ -f "$file" ] || continue
  while IFS=: read -r line text; do
    ref="$(sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/[[:space:]]+#.*$//; s/^["'\'']//; s/["'\'']$//' <<< "$text")"
    case "$ref" in ./*) continue ;; esac
    count=$((count + 1))
    if [[ ! "$ref" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+@[0-9a-f]{40}$ ]]; then
      echo "::error file=$file,line=$line::action not pinned to a full commit SHA: $ref"
      bad=$((bad + 1))
    fi
  done < <(grep -nE '^[[:space:]-]*uses:' "$file" || true)
done
[ "$count" -gt 0 ] || { echo "::error::check-action-pins: no actions found"; exit 1; }
[ "$bad" -eq 0 ] || { echo "::error::$bad of $count actions not pinned to a full SHA"; exit 1; }
echo "check-action-pins: all $count actions pinned to a full SHA"
