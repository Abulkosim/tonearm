#!/usr/bin/env bash
# Submits a zip or dmg to Apple's notary service and waits for the result.
# Usage: scripts/notarize.sh <file>
#
# Credentials, one of:
#   App Store Connect API key: NOTARY_KEY_P8 (base64 of the .p8), NOTARY_KEY_ID, NOTARY_ISSUER_ID
#   Apple ID:                  APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD (app-specific password)
set -euo pipefail

file="${1:?usage: notarize.sh <file>}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -n "${NOTARY_KEY_P8:-}" ]; then
  : "${NOTARY_KEY_ID:?NOTARY_KEY_ID is required with NOTARY_KEY_P8}"
  : "${NOTARY_ISSUER_ID:?NOTARY_ISSUER_ID is required with NOTARY_KEY_P8}"
  printf '%s' "$NOTARY_KEY_P8" | base64 --decode > "$work/AuthKey.p8"
  auth=(--key "$work/AuthKey.p8" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
elif [ -n "${APPLE_ID:-}" ]; then
  : "${APPLE_TEAM_ID:?APPLE_TEAM_ID is required with APPLE_ID}"
  : "${APPLE_APP_PASSWORD:?APPLE_APP_PASSWORD is required with APPLE_ID}"
  auth=(--apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_APP_PASSWORD")
else
  echo "no notarization credentials set" >&2
  exit 1
fi

echo "notarizing $file"
xcrun notarytool submit "$file" "${auth[@]}" --wait --timeout 30m \
  --output-format json > "$work/result.json" || true
cat "$work/result.json"
status="$(plutil -extract status raw -o - "$work/result.json" 2>/dev/null || echo unknown)"
if [ "$status" != Accepted ]; then
  id="$(plutil -extract id raw -o - "$work/result.json" 2>/dev/null || true)"
  if [ -n "$id" ]; then
    xcrun notarytool log "$id" "${auth[@]}" || true
  fi
  echo "notarization failed: $status" >&2
  exit 1
fi
