#!/usr/bin/env bash
# Proves that check-app.sh catches the mistake that kept v0.3.0 from starting on real Macs.
# check-app.sh must pass the good build, and fail on library validation for:
#   1. a copy of the good build re-signed like v0.3.0: the same certificate (no Team ID)
#      plus --options runtime. Its signatures are still valid, and CI runners still run it.
#   2. the published v0.3.0, pinned by SHA-256.
# Usage: SIGN_IDENTITY="Tonearm Self-Signed" scripts/launch-gate-test.sh <good Tonearm.app>
set -euo pipefail
cd "$(dirname "$0")/.."

good="${1:?usage: SIGN_IDENTITY=... launch-gate-test.sh <good Tonearm.app>}"
: "${SIGN_IDENTITY:?}"
v030_url=https://github.com/Abulkosim/tonearm/releases/download/v0.3.0/Tonearm-0.3.0.zip
v030_sha256=b6145243c0a3ccbf4690ccf936090eecfea093216b330cb6d6759297c706fa16
fail() { echo "::error::launch-gate-test: $*" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

expect_rejected() { # description, app
  if SKIP_LAUNCH=1 scripts/check-app.sh "$2" > "$work/out" 2>&1; then
    cat "$work/out"
    fail "check-app.sh passed $1"
  fi
  if ! grep -q 'library validation' "$work/out"; then
    cat "$work/out"
    fail "check-app.sh failed $1, but not on library validation"
  fi
  echo "rejected $1: $(grep 'library validation' "$work/out" | head -n 1)"
}

SKIP_LAUNCH=1 scripts/check-app.sh "$good" > "$work/out" 2>&1 || { cat "$work/out"; fail "check-app.sh fails the good build"; }
echo "passed the good build"

mkdir "$work/runtime"
app="$work/runtime/Tonearm.app"
ditto "$good" "$app"
fw="$app/Contents/Frameworks/Sparkle.framework"
fw_version="$(readlink "$fw/Versions/Current")"
sign() { codesign --force --options runtime --timestamp=none --sign "$SIGN_IDENTITY" "$@"; }
sign "$fw/Versions/$fw_version/Autoupdate"
sign "$fw/Versions/$fw_version/Updater.app"
sign "$fw"
sign --entitlements Resources/Tonearm.entitlements "$app"
codesign --verify --deep --strict "$app" || fail "the re-signed copy should still have valid signatures"
expect_rejected "a build signed like v0.3.0" "$app"

curl -fsSL --retry 3 -o "$work/v0.3.0.zip" "$v030_url"
echo "$v030_sha256  $work/v0.3.0.zip" | shasum -a 256 -c - > /dev/null || fail "Tonearm-0.3.0.zip changed"
mkdir "$work/v0.3.0"
ditto -x -k "$work/v0.3.0.zip" "$work/v0.3.0"
expect_rejected "the published v0.3.0" "$work/v0.3.0/Tonearm.app"
