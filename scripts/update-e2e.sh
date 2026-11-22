#!/usr/bin/env bash
# Updates an old Tonearm to the current one through Sparkle, with no human, from a feed on
# 127.0.0.1. Proves that a release built by these scripts can be found, downloaded, checked
# (EdDSA and code signature), installed and relaunched by an older version.
#
# 1. Make a throwaway EdDSA key with Sparkle's generate_keys.
# 2. Build NEW (the version in Info.plist) and OLD (0.0.1, build 1) from this commit with the
#    test feed and key (TONEARM_TEST_UPDATE=1, see build-app.sh), signed with SIGN_IDENTITY.
# 3. Package NEW with package.sh and appcast.sh, as a release does, and serve it.
# 4. Install OLD in a temporary Applications folder and open it. Sparkle checks at once
#    (there is no last check date), downloads, and Updater.swift installs right away because
#    no Tonearm window is open.
# 5. Assert the installed app is NEW, its signature verifies, and it stays up 10 s with its
#    main thread answering (scripts/ping-app.sh).
# 6. Again, with OLD built from the newest release tag older than NEW, so the updater code
#    that runs is the one users have installed. Its Info.plist gets the test feed, key and
#    build 1, and the app is signed again with SIGN_IDENTITY.
#
# CI only: it resets Tonearm's user defaults and kills Tonearm. TONEARM_E2E_LOCAL=1 overrides.
# Usage: SIGN_IDENTITY="Tonearm Self-Signed" scripts/update-e2e.sh <work dir>
# Environment: SIGN_IDENTITY (a codesign identity in the keychain, not ad-hoc),
#   EXPECT_SIGNING (passed to check-app.sh, default self-signed), OPENSSL (OpenSSL 3),
#   OLD_TAG (release tag for step 6; default: the newest vX.Y.Z tag on origin below NEW;
#   "none" skips step 6, for when an old tag no longer builds on the runner).
set -euo pipefail
cd "$(dirname "$0")/.."

work="${1:?usage: update-e2e.sh <work dir>}"
: "${SIGN_IDENTITY:?set SIGN_IDENTITY to a certificate identity}"
[ "$SIGN_IDENTITY" != - ] || { echo "update-e2e: needs a certificate, not ad-hoc" >&2; exit 1; }
if [ "${CI:-}" != true ] && [ "${TONEARM_E2E_LOCAL:-}" != 1 ]; then
  echo "update-e2e: resets Tonearm's settings and kills Tonearm; set TONEARM_E2E_LOCAL=1 to run outside CI" >&2
  exit 1
fi
OPENSSL="${OPENSSL:-$(brew --prefix openssl@3)/bin/openssl}"
export OPENSSL
EXPECT_SIGNING="${EXPECT_SIGNING:-self-signed}"
bundle_id=io.github.abulkosim.tonearm
plistbuddy=/usr/libexec/PlistBuddy
say() { echo "update-e2e: $*"; }
fail() { echo "::error::update-e2e: $*" >&2; exit 1; }
# Runs a command with a time limit; macOS has no timeout(1).
limit() { perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$@"; }

rm -rf "$work"
mkdir -p "$work/serve" "$work/Applications" "$work/old" "$work/logs" "$work/keys"
work="$(cd "$work" && pwd)"
chmod 700 "$work/keys"
start="$(date '+%Y-%m-%d %H:%M:%S')"
server_pid=""
account="tonearm-e2e-$$"
installed="$work/Applications/Tonearm.app"
exe="$installed/Contents/MacOS/Tonearm"

dump_logs() {
  log show --start "$start" --style compact --info --debug \
    --predicate 'subsystem BEGINSWITH "org.sparkle-project" OR process IN {"Tonearm", "Autoupdate", "Updater"} OR eventMessage CONTAINS[c] "sparkle"' \
    > "$work/logs/system.log" 2>&1 || true
  echo "--- http server"; cat "$work/logs/http.log" 2>/dev/null || true
  echo "--- system log (last 120 lines)"; tail -n 120 "$work/logs/system.log" || true
}
cleanup() {
  status=$?
  [ "$status" = 0 ] || dump_logs
  pkill -f "$exe" 2>/dev/null || true
  [ -z "$server_pid" ] || kill "$server_pid" 2>/dev/null || true
  security delete-generic-password -s https://sparkle-project.org -a "$account" > /dev/null 2>&1 || true
  rm -rf "$work/keys"
  exit "$status"
}
trap cleanup EXIT

new_version="$("$plistbuddy" -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
new_build="$(scripts/build-number.sh "$new_version")"

# build-app.sh must refuse the overrides without TONEARM_TEST_UPDATE=1. It checks before building.
if TONEARM_TEST_UPDATE='' TONEARM_TEST_FEED_URL=http://127.0.0.1:1/appcast.xml \
     TONEARM_TEST_ED_KEY="$("$OPENSSL" rand -base64 32)" scripts/build-app.sh > "$work/logs/refuse.log" 2>&1; then
  fail "build-app.sh accepted test overrides without TONEARM_TEST_UPDATE=1"
fi
grep -q 'refusing test overrides' "$work/logs/refuse.log" || { cat "$work/logs/refuse.log"; fail "build-app.sh failed for another reason"; }
say "build-app.sh refuses test overrides without TONEARM_TEST_UPDATE=1"

# 1. Throwaway EdDSA key from Sparkle's generate_keys (kept in the login keychain, deleted on exit).
scripts/sparkle-tools.sh "$work/sparkle"
gk="$work/sparkle/bin/generate_keys"
limit 120 "$gk" --account "$account" > "$work/logs/generate_keys.log" 2>&1 \
  || { cat "$work/logs/generate_keys.log"; fail "generate_keys could not make a key"; }
public_key="$(limit 60 "$gk" --account "$account" -p)"
limit 60 "$gk" --account "$account" -x "$work/keys/ed25519.key" > /dev/null
seed="$(tr -d '\n' < "$work/keys/ed25519.key")"
derived="$(SEED="$seed" scripts/ed25519-public-key.sh)"
[ "$derived" = "$public_key" ] || fail "generate_keys printed $public_key, but the exported key derives $derived"
say "EdDSA key from generate_keys: $public_key"

# Before any Tonearm starts: the main thread check below sends it Apple Events.
scripts/ping-app.sh prepare

# Serve the feed on a free port.
port="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -I -u -m http.server "$port" --bind 127.0.0.1 --directory "$work/serve" > "$work/logs/http.log" 2>&1 &
server_pid=$!
feed="http://127.0.0.1:$port/appcast.xml"

# 2. OLD and NEW. The second swift build is a no-op; only Info.plist and signatures change.
build() { # version build
  TONEARM_TEST_UPDATE=1 TONEARM_TEST_FEED_URL="$feed" TONEARM_TEST_ED_KEY="$public_key" \
    VERSION="$1" BUILD="$2" scripts/build-app.sh > "$work/logs/build-$1.log" 2>&1 \
    || { tail -n 60 "$work/logs/build-$1.log"; fail "build-app.sh failed for $1"; }
  EXPECT_SIGNING="$EXPECT_SIGNING" EXPECT_VERSION="$1" EXPECT_BUILD="$2" EXPECT_FEED_URL="$feed" EXPECT_ED_KEY="$public_key" \
    scripts/check-app.sh build/Tonearm.app
}
build 0.0.1 1
ditto build/Tonearm.app "$work/old/Tonearm.app"
build "$new_version" "$new_build"

# 3. Package and sign the update the way release.yml does, then point the enclosure at the
# local server. The EdDSA signature covers the zip, not the URL.
VERSION="$new_version" scripts/package.sh > "$work/logs/package.log"
zip="dist/Tonearm-$new_version.zip"
VERSION="$new_version" BUILD="$new_build" TAG="v$new_version" REPO=Abulkosim/tonearm \
  SPARKLE_ED_PRIVATE_KEY="$seed" SPARKLE_PUBLIC_KEY="$public_key" \
  SIGN_UPDATE="$work/sparkle/bin/sign_update" \
  scripts/appcast.sh "$zip" "$work/appcast.xml"
sed "s#url=\"https://github.com/[^\"]*/$(basename "$zip")\"#url=\"http://127.0.0.1:$port/$(basename "$zip")\"#" \
  "$work/appcast.xml" > "$work/serve/appcast.xml"
grep -q "url=\"http://127.0.0.1:$port/" "$work/serve/appcast.xml" || fail "could not point the appcast at the local server"
cp "$zip" "$work/serve/"
scripts/verify-appcast.sh "$work/serve/appcast.xml" "$work/serve/$(basename "$zip")" "$public_key"
for _ in $(seq 1 20); do
  curl -fsS -o /dev/null "$feed" && break
  sleep 0.5
done
curl -fsS "$feed" > /dev/null || fail "the feed server does not answer"
cat "$work/serve/appcast.xml"

# 4 and 5. Installs OLD, opens it like a user who has used it before, and waits for NEW.
# The welcome window was shown (it would hold the install back while it is the key window);
# Sparkle's settings are the Info.plist defaults, and there is no last check date, so Sparkle
# checks right away.
update_from() { # old app, label
  local old="$1" label="$2" old_build current old_pid="" new_pid="" deadline began
  pkill -f "$exe" 2> /dev/null || true
  rm -rf "$installed"
  defaults delete "$bundle_id" > /dev/null 2>&1 || true
  defaults write "$bundle_id" welcomeShown -bool true
  ditto "$old" "$installed"
  old_build="$("$plistbuddy" -c 'Print :CFBundleVersion' "$installed/Contents/Info.plist")"
  local http_lines; http_lines="$(wc -l < "$work/logs/http.log")"
  open -n "$installed"
  for _ in $(seq 1 30); do
    old_pid="$(pgrep -f "$exe" | head -n 1 || true)"
    [ -n "$old_pid" ] && break
    sleep 1
  done
  [ -n "$old_pid" ] || fail "$label: OLD did not start"
  say "$label: OLD build $old_build running as $old_pid, waiting for the update"

  began=$SECONDS
  deadline=$((SECONDS + 300))
  while :; do
    current="$("$plistbuddy" -c 'Print :CFBundleVersion' "$installed/Contents/Info.plist" 2> /dev/null || true)"
    [ "$current" = "$new_build" ] && break
    [ "$SECONDS" -lt "$deadline" ] || fail "$label: no update after 300 s; installed build is '$current'"
    sleep 5
  done
  say "$label: installed bundle is now build $current after $((SECONDS - began)) s"
  tail -n "+$((http_lines + 1))" "$work/logs/http.log" > "$work/logs/http-$label.log"
  grep -q "GET /appcast.xml" "$work/logs/http-$label.log" || fail "$label: Sparkle never fetched the feed"
  grep -q "GET /$(basename "$zip")" "$work/logs/http-$label.log" || fail "$label: Sparkle never downloaded the update"

  # NEW must be relaunched (by Sparkle), stay up and keep its main thread answering.
  for _ in $(seq 1 60); do
    new_pid="$(pgrep -f "$exe" | grep -vx "$old_pid" | head -n 1 || true)"
    [ -n "$new_pid" ] && break
    sleep 1
  done
  [ -n "$new_pid" ] || fail "$label: NEW was not relaunched after the update"
  if kill -0 "$old_pid" 2> /dev/null; then fail "$label: OLD ($old_pid) is still running"; fi
  answers="$(scripts/ping-app.sh "$new_pid" 10)" || fail "$label: NEW ($new_pid) exited or hung within 10 s"
  say "$label: NEW running as $new_pid for 10 s; $answers"

  codesign --verify --deep --strict --verbose=2 "$installed"
  EXPECT_SIGNING="$EXPECT_SIGNING" EXPECT_VERSION="$new_version" EXPECT_BUILD="$new_build" \
    EXPECT_FEED_URL="$feed" EXPECT_ED_KEY="$public_key" scripts/check-app.sh "$installed"
  say "ok: $label (build $old_build) updated itself to $new_version ($new_build) from $feed"
}
update_from "$work/old/Tonearm.app" this-commit

# 6. OLD from the newest release older than NEW, built with that release's own scripts.
old_tag="${OLD_TAG:-}"
if [ "$old_tag" = none ]; then
  echo "::warning::update-e2e: OLD_TAG=none; skipped the update from the latest release's code"
  dump_logs > /dev/null
  exit 0
fi
if [ -z "$old_tag" ]; then
  old_tag="$(git ls-remote --tags --refs origin 'v*' | sed 's:.*refs/tags/::' \
    | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V \
    | while read -r t; do [ "$(scripts/build-number.sh "${t#v}")" -lt "$new_build" ] && echo "$t"; done \
    | tail -n 1 || true)"
fi
[ -n "$old_tag" ] || fail "no release tag older than $new_version"
git fetch --quiet --depth 1 origin "refs/tags/$old_tag:refs/tags/$old_tag"
mkdir -p "$work/release-src"
git archive "$old_tag" | tar -x -C "$work/release-src"
(cd "$work/release-src" && SIGN_IDENTITY="$SIGN_IDENTITY" BUILD=1 scripts/build-app.sh) > "$work/logs/build-$old_tag.log" 2>&1 \
  || { tail -n 60 "$work/logs/build-$old_tag.log"; fail "could not build $old_tag"; }
release_app="$work/release-src/build/Tonearm.app"
# Make sure OLD is that release: its version, with the build number forced to 1.
release_version="$("$plistbuddy" -c 'Print :CFBundleShortVersionString' "$release_app/Contents/Info.plist")"
release_build="$("$plistbuddy" -c 'Print :CFBundleVersion' "$release_app/Contents/Info.plist")"
[ "$release_version" = "${old_tag#v}" ] || fail "built $old_tag, but its Info.plist says version $release_version"
[ "$release_build" = 1 ] || fail "built $old_tag with build $release_build, expected 1"
say "built $old_tag as $release_version ($release_build)"
plutil -replace SUFeedURL -string "$feed" "$release_app/Contents/Info.plist"
plutil -replace SUPublicEDKey -string "$public_key" "$release_app/Contents/Info.plist"
# Sign the app again the way that release's build-app.sh signs a self-signed app (no runtime).
codesign --force --timestamp=none --sign "$SIGN_IDENTITY" \
  --entitlements "$work/release-src/Resources/Tonearm.entitlements" "$release_app"
codesign --verify --deep --strict "$release_app"
update_from "$release_app" "$old_tag"
dump_logs > /dev/null
