#!/usr/bin/env bash
# Lets processes on a GitHub macOS runner send Apple Events to an app, without the consent
# prompt nobody would click, by writing rows into the user TCC database. That works on the
# runners because SIP is off there. scripts/e2e.sh does the same for the fake Spotify.
#
# The clients are osascript, bash, the runner's agents (macOS holds them responsible for
# every process a job starts) and any paths given. Run it before anything sends an event:
# an event that already waits for consent is not released by a later grant.
#
# GitHub Actions only. Usage: scripts/allow-apple-events.sh <bundle id> [client path...]
set -euo pipefail

target="${1:?usage: allow-apple-events.sh <bundle id> [client path...]}"
shift
[ "${GITHUB_ACTIONS:-}" = true ] || { echo "allow-apple-events: GitHub Actions only; it edits the TCC database" >&2; exit 1; }
[[ "$target" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "allow-apple-events: bad bundle id $target" >&2; exit 1; }

db="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
sql="begin;"
for client in /usr/bin/osascript /bin/bash /opt/hca/hosted-compute-agent \
              /usr/local/opt/runner/provisioner/provisioner "$@"; do
  [[ "$client" != *"'"* ]] || { echo "allow-apple-events: bad client path $client" >&2; exit 1; }
  sql="$sql insert or replace into access
    (service, client, client_type, auth_value, auth_reason, auth_version, csreq, policy_id,
     indirect_object_identifier_type, indirect_object_identifier, indirect_object_code_identity,
     flags, last_modified)
    values ('kTCCServiceAppleEvents', '$client', 1, 2, 3, 1, NULL, NULL,
     0, '$target', NULL, 0, cast(strftime('%s','now') as integer));"
done
# tccd may hold the database lock for a moment: a write then failed with "database is
# locked" (release dry run 45037275623). Wait for the lock, up to 30 s, instead of failing,
# and write every row in one transaction.
sudo sqlite3 -cmd '.timeout 30000' "$db" "$sql commit;"
# tccd caches decisions.
sudo killall tccd 2> /dev/null || true
sleep 1
echo "Apple Events to $target allowed in the user TCC database"
