#!/usr/bin/env bash
# Walks a new user's path with the PUBLISHED release, on a clean Mac (a GitHub runner):
# nothing here builds Tonearm from source. Run by .github/workflows/product-check.yml.
#
#   setup        Resolves the release (releases/latest), unpacks that tag's own scripts and
#                tools (they match the binary under test), writes the history fixture.
#   dmg          README install: curl the DMG, quarantine it like a browser, check
#                SHA256SUMS.txt, mount, copy to /Applications, try a launch while
#                quarantined, then the README's xattr step; signature, version, build.
#   brew         brew install --cask abulkosim/tap/tonearm, the same checks, same binary.
#   launch       A first launch: stays up, main thread answers, quits when asked.
#   e2e          scripts/e2e.sh and scripts/idle-cost.sh against the installed app.
#   liner-notes  The slow twin against the installed binary; Liner Notes renders and the
#                live window.
#   update       Installs OLD_TAG's published DMG, gives it a history, and lets it update
#                itself through the real public feed. The history must survive.
#   zap          brew uninstall --zap --cask tonearm: app, settings and history gone.
#   summary      Prints the results table.
#
# CI only: it installs into /Applications, deletes Tonearm's settings and history, and
# edits the TCC database.
# Environment: EXPECT_VERSION (default: whatever releases/latest is), OLD_TAG (default:
#   the newest vX.Y.Z tag below it), PC_WORK (default $RUNNER_TEMP/product-check).
set -euo pipefail

[ "${CI:-}" = true ] || { echo "product-check: CI only; it replaces /Applications/Tonearm.app and Tonearm's data" >&2; exit 1; }
cmd="${1:?usage: product-check.sh setup|dmg|brew|launch|e2e|liner-notes|update|zap|summary}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
work="${PC_WORK:-${RUNNER_TEMP:?}/product-check}"
out="$work/out"
src="$work/src"
fixture="$work/fixture"
results="$out/results.tsv"
releases=https://github.com/Abulkosim/tonearm/releases
bundle_id=io.github.abulkosim.tonearm
app=/Applications/Tonearm.app
bin="$app/Contents/MacOS/Tonearm"
history_dir="$HOME/Library/Application Support/Tonearm"
db="$history_dir/history.sqlite"
plistbuddy=/usr/libexec/PlistBuddy
mkdir -p "$out"

notes=()
note() { notes+=("$*"); echo "product-check: $*"; }
fail() { echo "::error::product-check $cmd: $*" >&2; notes+=("FAILED: $*"); exit 1; }
# Runs a command with a time limit; macOS has no timeout(1).
limit() { perl -e 'alarm shift; exec @ARGV or die "exec: $!"' "$@"; }
record() {
  local status=$?
  [ "$cmd" = summary ] && return
  local verdict=PASS details="" n
  if [ "$status" != 0 ]; then
    verdict=FAIL
    [[ "${notes[*]:-}" == *FAILED:* ]] || notes+=("FAILED: exit $status, see the step's log")
  fi
  for n in ${notes[@]+"${notes[@]}"}; do details="${details:+$details; }$n"; done
  printf '%s\t%s\t%s\n' "$cmd" "$verdict" "$details" >> "$results"
}
trap record EXIT

state() { cat "$work/state/$1"; }
save() { mkdir -p "$work/state"; printf '%s\n' "$2" > "$work/state/$1"; }
plist_get() { "$plistbuddy" -c "Print :$2" "$1/Contents/Info.plist"; }
binary_sha() { shasum -a 256 < "$1/Contents/MacOS/Tonearm" | cut -d ' ' -f 1; }
quarantine_of() { xattr -p com.apple.quarantine "$1" 2> /dev/null || echo none; }

# Quits Tonearm the way a user would (Apple Event "quit"), then makes sure it is gone.
quit_tonearm() {
  pgrep -x Tonearm > /dev/null || return 0
  limit 20 osascript -e "tell application id \"$bundle_id\" to quit" > /dev/null 2>&1 || true
  for _ in $(seq 1 100); do
    pgrep -x Tonearm > /dev/null || return 0
    sleep 0.1
  done
  return 1
}
kill_tonearm() {
  pkill -x Tonearm 2> /dev/null || true
  for _ in $(seq 1 50); do pgrep -x Tonearm > /dev/null || return 0; sleep 0.1; done
  pkill -9 -x Tonearm 2> /dev/null || true
  sleep 0.5
}
# A user who never ran Tonearm: no settings, no history.
forget_user() {
  defaults delete "$bundle_id" > /dev/null 2>&1 || true
  rm -rf "$history_dir"
}
# Waits for a Tonearm process that runs $bin and prints its pid.
wait_for_pid() { # seconds, pid to ignore
  local pid
  for _ in $(seq 1 $(($1 * 10))); do
    pid="$(pgrep -x Tonearm | grep -vx "${2:-0}" | head -n 1 || true)"
    if [ -n "$pid" ]; then echo "$pid"; return 0; fi
    sleep 0.1
  done
  return 1
}
# Tonearm's normal windows on screen, as "NUMBER WIDTHxHEIGHT".
windows() {
  limit 30 osascript -l JavaScript -e 'ObjC.import("CoreGraphics");
    const all = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
    all.filter(w => w.kCGWindowOwnerName === "Tonearm" && w.kCGWindowLayer === 0)
       .map(w => w.kCGWindowNumber + " " + w.kCGWindowBounds.Width + "x" + w.kCGWindowBounds.Height).join(", ")'
}
# Normal-layer windows on screen owned by anything but Tonearm, Finder, the Dock and the
# menu bar, as "PID OWNER WIDTHxHEIGHT": a system alert, for example.
foreign_windows() {
  limit 30 osascript -l JavaScript -e 'ObjC.import("CoreGraphics");
    const skip = ["Tonearm", "Finder", "Dock", "Window Server", "SystemUIServer", "Control Center", "Spotlight", "WindowManager", "Wallpaper"];
    const all = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)));
    all.filter(w => !skip.includes(w.kCGWindowOwnerName) && w.kCGWindowBounds.Height > 50)
       .map(w => w.kCGWindowOwnerPID + " " + w.kCGWindowOwnerName.replace(/ /g, "_") + " " + w.kCGWindowBounds.Width + "x" + w.kCGWindowBounds.Height).join(", ")'
}
# One Apple Event to a pid with Tools/LaunchPing (built by ping-app.sh prepare); prints
# "ok <ms> ms" if its main thread answers within 5 s.
ping_once() {
  limit 15 "${TMPDIR:-/tmp}/tonearm-launch-ping-$(shasum -a 256 < "$src/Tools/LaunchPing/main.swift" | cut -c 1-16)" "$1" 5
}
# The release's own app checks: every signature, entitlements, Info.plist against the
# tag's source, universal binary, macOS 13 minimum, and a launch on arm64 and x86_64.
check_bundle() { # app, version, build
  EXPECT_SIGNING=self-signed EXPECT_VERSION="$2" EXPECT_BUILD="$3" "$src/scripts/check-app.sh" "$1" > "$work/check-app.log" 2>&1 \
    || { cat "$work/check-app.log"; fail "check-app.sh rejected $1"; }
  cat "$work/check-app.log"
  codesign --verify --deep --strict "$1" || fail "codesign --verify --deep --strict failed for $1"
}
# Downloads a DMG with curl and gives it the quarantine flag a browser sets.
download() { # url, file
  rm -f "$2"
  limit 300 curl -fsSL --retry 3 -o "$2" "$1" || fail "could not download $1"
  xattr -w com.apple.quarantine "0083;$(printf '%x' "$(date +%s)");Safari;$(uuidgen)" "$2"
}
# Checks a file against its line in a SHA256SUMS.txt.
check_sum() { # file, name in sums, sums file
  local want got
  want="$(awk -v n="$2" '$2 == n {print $1}' "$3")"
  got="$(shasum -a 256 < "$1" | cut -d ' ' -f 1)"
  [ -n "$want" ] || fail "$2 is not in SHA256SUMS.txt"
  [ "$want" = "$got" ] || fail "$2: SHA-256 is $got, SHA256SUMS.txt says $want"
  echo "$got"
}
# Mounts a DMG like a double-click, copies Tonearm.app to /Applications like a drag
# (ditto keeps extended attributes, as Finder does), unmounts. Prints the quarantine flag
# the mounted copy carried.
install_dmg() { # dmg
  local mnt="$work/mnt" q
  mkdir -p "$mnt"
  limit 120 hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$1" > /dev/null || fail "hdiutil attach failed for $1"
  [ -d "$mnt/Tonearm.app" ] || { hdiutil detach "$mnt" -force > /dev/null; fail "the DMG has no Tonearm.app"; }
  [ "$(readlink "$mnt/Applications" || true)" = /Applications ] \
    || { hdiutil detach "$mnt" -force > /dev/null; fail "the DMG has no Applications link to drag onto"; }
  q="$(quarantine_of "$mnt/Tonearm.app")"
  rm -rf "$app"
  ditto "$mnt/Tonearm.app" "$app"
  for attempt in 1 2 3; do
    hdiutil detach "$mnt" > /dev/null 2>&1 && break
    [ "$attempt" = 3 ] && hdiutil detach "$mnt" -force > /dev/null
    sleep 2
  done
  echo "$q"
}
gatekeeper() { # app: spctl's verdict, one line
  local verdict
  verdict="$(spctl --assess --type execute -vv "$1" 2>&1 | tr '\n' ' ' | sed 's/ *$//')" || true
  echo "$verdict"
}
require_installed() {
  [ -x "$bin" ] || fail "no $app; an earlier step failed"
  [ "$(plist_get "$app" CFBundleShortVersionString)" = "$(state version)" ] \
    || fail "$app is $(plist_get "$app" CFBundleShortVersionString), not $(state version); an earlier step failed"
}

case "$cmd" in
setup)
  latest="$(curl -fsSI "$releases/latest" | tr -d '\r' | sed -n 's#^location: .*/releases/tag/##Ip')"
  [ -n "$latest" ] || fail "could not resolve $releases/latest"
  version="${EXPECT_VERSION:-${latest#v}}"
  [ "$latest" = "v$version" ] || fail "releases/latest is $latest, expected v$version"
  git -C "$repo" fetch --quiet --depth 1 origin "+refs/tags/v*:refs/tags/v*"
  old_tag="${OLD_TAG:-}"
  if [ -z "$old_tag" ]; then
    old_tag="$(git -C "$repo" tag -l 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V \
      | awk -v t="v$version" '$0 == t {print prev; exit} {prev = $0}')"
  fi
  [ -n "$old_tag" ] || fail "no release before v$version"
  rm -rf "$src" "$work/state"
  mkdir -p "$src"
  git -C "$repo" archive "v$version" | tar -x -C "$src"
  build="$("$src/scripts/build-number.sh" "$version")"
  [ "$("$plistbuddy" -c 'Print :CFBundleVersion' "$src/Resources/Info.plist")" = "$build" ] \
    || fail "v$version's Info.plist does not say build $build"
  save version "$version"
  save build "$build"
  save old_tag "$old_tag"
  sw_vers
  note "release v$version (build $build), update from $old_tag; $(sw_vers -productName) $(sw_vers -productVersion) $(uname -m); Gatekeeper: $(spctl --status 2>&1)"
  [ ! -e "$app" ] || fail "$app already exists on a clean runner"
  [ ! -e /Applications/Spotify.app ] || fail "Spotify is installed; e2e.sh needs a Mac without it"
  pgrep -x Tonearm > /dev/null && fail "Tonearm is running on a clean runner"
  forget_user
  python3 -I "$src/scripts/make-history-fixture.py" "$fixture/export" --zip "$fixture/export.zip"
  # The ping tool (Tools/LaunchPing), and Apple Events from it, osascript and bash to Tonearm.
  "$src/scripts/ping-app.sh" prepare
  ;;

dmg)
  version="$(state version)"; build="$(state build)"
  dl="$HOME/Downloads"
  mkdir -p "$dl"
  download "$releases/latest/download/Tonearm.dmg" "$dl/Tonearm.dmg"
  limit 60 curl -fsSL --retry 3 -o "$work/SHA256SUMS.txt" "$releases/latest/download/SHA256SUMS.txt" || fail "no SHA256SUMS.txt"
  sum="$(check_sum "$dl/Tonearm.dmg" Tonearm.dmg "$work/SHA256SUMS.txt")"
  check_sum "$dl/Tonearm.dmg" "Tonearm-$version.dmg" "$work/SHA256SUMS.txt" > /dev/null
  note "Tonearm.dmg $(stat -f %z "$dl/Tonearm.dmg") bytes, SHA-256 ${sum:0:12}… matches SHA256SUMS.txt (and Tonearm-$version.dmg)"
  note "download quarantined: $(quarantine_of "$dl/Tonearm.dmg" | cut -d ';' -f 1,3)"
  q="$(install_dmg "$dl/Tonearm.dmg")"
  # The published binary, for the Homebrew and update steps to compare with.
  save dmg_sha "$(binary_sha "$app")"
  if [ "$q" = none ]; then
    # Finder copies the flag from a quarantined image; hdiutil may not. Do what Finder does.
    xattr -w com.apple.quarantine "$(quarantine_of "$dl/Tonearm.dmg")" "$app"
    note "hdiutil did not propagate quarantine to the mounted app; set it on the copy by hand, as Finder would"
  else
    note "mounted Tonearm.app quarantined ($(cut -d ';' -f 1 <<< "$q")), copied to /Applications with the flag"
  fi
  [ "$(quarantine_of "$app")" != none ] || fail "the installed app lost its quarantine flag before the README step"
  note "Gatekeeper on the quarantined app: $(gatekeeper "$app")"

  # A double-click while the app is still quarantined. The README says macOS blocks it.
  # open(1) waits for the answer to Gatekeeper's alert, which nobody clicks here, so it
  # runs in the background with a time limit. macOS 15 starts the process (translocated)
  # and holds it while the alert shows, so "blocked" means: an alert from another process
  # is on screen, and Tonearm's main thread never runs (no welcome window, no answer).
  forget_user
  limit 20 open -n "$app" > "$work/open-quarantined.log" 2>&1 &
  open_pid=$!
  sleep 10
  screencapture -x "$out/gatekeeper-alert.png" || echo "::warning::screencapture failed"
  echo "product-check: looking for the alert and the held process"
  alert="$(foreign_windows)"
  shown="$(windows)"
  qpid="$(pgrep -x Tonearm | head -n 1 || true)"
  answer=none
  if [ -n "$qpid" ]; then
    echo "product-check: pinging the held process $qpid"
    answer="$(ping_once "$qpid" 2>&1 || true)"
  fi
  qexe="$( [ -z "$qpid" ] || ps -o comm= -p "$qpid" || true)"
  kill_tonearm
  wait "$open_pid" || true
  # Dismiss the alert, so it is not in later screenshots: quit whoever owns it.
  { grep -oE '(^|, )[0-9]+ [^ ,]+' <<< "$alert" || true; } | sed 's/^, //' | { grep -v ' loginwindow$' || true; } | while read -r owner _; do
    kill -9 "$owner" 2> /dev/null || true
  done
  sleep 2
  still="$(foreign_windows)"
  [ -z "$still" ] || echo "::warning::product-check: the alert is still on screen ($still); later screenshots show it"
  note "double-click while quarantined: alert windows (pid owner size): ${alert:-none}; Tonearm process: ${qexe:-none}; its windows: ${shown:-none}; main thread: ${answer:-no answer in 15 s}"
  [ -n "$alert" ] || fail "no Gatekeeper alert after a double-click on the quarantined app"
  [ -z "$shown" ] || fail "the quarantined app showed a window: $shown"
  [[ "$answer" != ok* ]] || fail "the quarantined app ran: its main thread answered ($answer)"
  forget_user

  # README: "Or in Terminal, on any version".
  xattr -dr com.apple.quarantine /Applications/Tonearm.app
  left="$(xattr -lr "$app" | grep -c com.apple.quarantine || true)"
  [ "$left" = 0 ] || fail "$left files still quarantined after the README's xattr command"
  note "after the README xattr step: no quarantine; Gatekeeper: $(gatekeeper "$app")"
  check_bundle "$app" "$version" "$build"
  authority="$(codesign -dvv "$app" 2>&1 | sed -n 's/^Authority=//p' | head -n 1)"
  note "check-app.sh ok: $(plist_get "$app" CFBundleShortVersionString) ($(plist_get "$app" CFBundleVersion)), signed by $authority, universal, launched arm64 + x86_64"
  ;;

brew)
  version="$(state version)"; build="$(state build)"
  kill_tonearm
  rm -rf "$app"
  forget_user
  note "Homebrew $(brew --version | head -n 1 | cut -d ' ' -f 2)"
  # Exactly the README's command.
  began=$SECONDS
  brew install --cask abulkosim/tap/tonearm 2>&1 | tee "$out/brew-install.log"
  [ "${PIPESTATUS[0]}" = 0 ] || fail "brew install --cask abulkosim/tap/tonearm failed"
  note "brew install took $((SECONDS - began)) s"
  brew list --cask tonearm > /dev/null || fail "brew does not list the tonearm cask"
  [ -d "$app" ] || fail "brew installed no $app"
  cached="$(brew --cache --cask abulkosim/tap/tonearm)"
  [ -f "$cached" ] || fail "no cached download at $cached"
  cq="$(quarantine_of "$cached")"
  [ "$cq" != none ] || fail "Homebrew did not quarantine its download, so the cask's quarantine removal is untested"
  left="$(xattr -lr "$app" | grep -c com.apple.quarantine || true)"
  [ "$left" = 0 ] || fail "the cask left $left quarantined files in $app (its postflight should remove the flag)"
  note "download quarantined by Homebrew ($(cut -d ';' -f 3 <<< "$cq")); installed app has no quarantine"
  note "Gatekeeper: $(gatekeeper "$app")"
  check_bundle "$app" "$version" "$build"
  [ "$(binary_sha "$app")" = "$(state dmg_sha)" ] || fail "the cask installed a different binary than the DMG"
  note "check-app.sh ok: $(plist_get "$app" CFBundleShortVersionString) ($(plist_get "$app" CFBundleVersion)); binary identical to the DMG's"
  ;;

launch)
  require_installed
  kill_tonearm
  forget_user
  before="$(binary_sha "$app") $(plist_get "$app" CFBundleVersion)"
  # Like a double-click. Sparkle's automatic checks stay on, as for a user: the feed has
  # nothing newer, so the bundle must not change.
  open "$app"
  pid="$(wait_for_pid 10)" || fail "Tonearm did not start within 10 s"
  running="$(ps -o comm= -p "$pid")"
  [ "$running" = "$bin" ] || fail "the process runs $running, not $bin (translocated?)"
  answers="$("$src/scripts/ping-app.sh" "$pid" 20)" || fail "the main thread stopped answering or the app exited"
  note "pid $pid: $answers"
  shown="$(windows)"
  note "windows at first launch: ${shown:-none}"
  screencapture -x "$out/first-launch.png" || echo "::warning::screencapture failed"
  [ -n "$shown" ] || fail "no welcome window at the first launch"
  quit_tonearm || fail "Tonearm did not quit within 10 s of an Apple Event quit"
  note "quit on request"
  after="$(binary_sha "$app") $(plist_get "$app" CFBundleVersion)"
  [ "$after" = "$before" ] || fail "the bundle changed during the launch"
  # A second launch: no window, still answering.
  open "$app"
  pid="$(wait_for_pid 10)" || fail "Tonearm did not start the second time"
  answers="$("$src/scripts/ping-app.sh" "$pid" 10)" || fail "second launch: the main thread stopped answering"
  shown="$(windows)"
  [ -z "$shown" ] || fail "a window opened at the second launch: $shown"
  note "second launch: no window, $answers"
  quit_tonearm || fail "Tonearm did not quit the second time"
  ;;

e2e)
  require_installed
  kill_tonearm
  before="$(binary_sha "$app")"
  status=0
  TONEARM_APP="$app" E2E_DIR="$work/e2e" "$src/scripts/e2e.sh" || status=$?
  mkdir -p "$out/e2e"
  cp -R "$work/e2e/report/." "$out/e2e/" 2> /dev/null || true
  note "e2e.sh against $app: $(tail -n 1 "$work/e2e/report/report.txt" 2> /dev/null || echo 'no report'), exit $status"
  [ "$status" = 0 ] || fail "e2e.sh failed"
  status=0
  E2E_DIR="$work/e2e" "$src/scripts/idle-cost.sh" "$app" "$work/e2e/report" || status=$?
  cp "$work/e2e/report/idle-cost"* "$out/e2e/" 2> /dev/null || true
  note "idle-cost: $(tr '\n' ' ' < "$work/e2e/report/idle-cost.txt" 2> /dev/null | tr -s ' ')"
  [ "$status" = 0 ] || fail "idle-cost.sh failed"
  [ "$(binary_sha "$app")" = "$before" ] || fail "the bundle changed during the e2e run"
  kill_tonearm
  forget_user
  ;;

liner-notes)
  require_installed
  kill_tonearm
  python3 -I "$src/scripts/history-twin.py" check --app "$bin" --fixture "$fixture/export" \
    --zip "$fixture/export.zip" --work "$work/history" 2>&1 | tee "$out/twin.log"
  [ "${PIPESTATUS[0]}" = 0 ] || fail "the slow twin disagrees with the installed binary"
  note "$(grep -E '^(fixture|tonearm|twin):' "$out/twin.log" | tr '\n' ';' | sed 's/;$//')"
  note "$(grep '^twin check passed' "$out/twin.log")"
  rm -rf "$out/liner-notes"
  "$bin" --liner-notes "$out/liner-notes" --history "$fixture/export" > "$out/liner-notes-render.log" 2>&1 \
    || { cat "$out/liner-notes-render.log"; fail "--liner-notes failed"; }
  # Someone who has used Tonearm: the welcome window was shown (liner-notes-live.sh checks
  # that no window opens at launch).
  defaults write "$bundle_id" welcomeShown -bool true
  "$src/scripts/liner-notes-live.sh" "$app" "$fixture/export" "$out/liner-notes" 2>&1 | tee "$out/liner-notes-live.log"
  [ "${PIPESTATUS[0]}" = 0 ] || fail "liner-notes-live.sh failed"
  pngs="$(find "$out/liner-notes" -name '*.png' | wc -l | tr -d ' ')"
  [ "$pngs" -ge 3 ] || fail "only $pngs Liner Notes images"
  note "rendered $pngs PNGs; $(tail -n 1 "$out/liner-notes-live.log")"
  kill_tonearm
  forget_user
  ;;

update)
  version="$(state version)"; build="$(state build)"; old_tag="$(state old_tag)"
  old_version="${old_tag#v}"
  kill_tonearm
  rm -rf "$app"
  forget_user
  # The old release, installed the README way.
  dl="$HOME/Downloads"
  mkdir -p "$dl"
  download "$releases/download/$old_tag/Tonearm.dmg" "$dl/Tonearm-old.dmg"
  limit 60 curl -fsSL --retry 3 -o "$work/SHA256SUMS-old.txt" "$releases/download/$old_tag/SHA256SUMS.txt" || fail "no SHA256SUMS.txt for $old_tag"
  check_sum "$dl/Tonearm-old.dmg" Tonearm.dmg "$work/SHA256SUMS-old.txt" > /dev/null
  install_dmg "$dl/Tonearm-old.dmg" > /dev/null
  xattr -dr com.apple.quarantine "$app"
  [ "$(plist_get "$app" CFBundleShortVersionString)" = "$old_version" ] || fail "the $old_tag DMG holds $(plist_get "$app" CFBundleShortVersionString)"
  old_build="$(plist_get "$app" CFBundleVersion)"
  codesign --verify --deep --strict "$app" || fail "$old_tag's signature does not verify"
  old_sha="$(binary_sha "$app")"
  old_feed="$(plist_get "$app" SUFeedURL)"
  [ "$old_feed" = "$releases/latest/download/appcast.xml" ] || fail "$old_tag's feed is $old_feed"
  limit 60 curl -fsSL --retry 3 -o "$work/appcast.xml" "$old_feed" || fail "could not fetch $old_feed"
  feed_build="$(sed -n 's/.*<sparkle:version>\([0-9]*\)<.*/\1/p' "$work/appcast.xml" | head -n 1)"
  [ "$feed_build" = "$build" ] || fail "the public feed offers build '$feed_build', not $build"
  note "installed $old_tag from its DMG: $old_version ($old_build), checksum and signature ok; its feed $old_feed offers build $feed_build"

  # A history made by the old release, where the app keeps it.
  mkdir -p "$history_dir"
  "$bin" --stats "$fixture/export.zip" --db "$db" > /dev/null 2> "$work/old-import.log" \
    || { cat "$work/old-import.log"; fail "$old_tag could not import the fixture"; }
  "$bin" --stats - --db "$db" --json --tz UTC --period all > "$work/stats-old.json" \
    || fail "$old_tag could not read its own history"
  python3 -I - "$db" > "$work/db-old.txt" << 'PY'
import sqlite3, sys
c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
print("user_version", c.execute("pragma user_version").fetchone()[0])
for (t,) in c.execute("select name from sqlite_master where type = 'table' and name not like 'sqlite_%' order by name"):
    print(t, c.execute('select count(*) from "%s"' % t).fetchone()[0])
PY
  totals() { python3 -I -c 'import json, sys; m = json.load(open(sys.argv[1]))["music"]; print("%d plays, %d min, %d artists" % (m["listens"], m["ms"] // 60000, m["uniqueArtists"]))' "$1"; }
  note "$old_tag history: $(tr '\n' ' ' < "$work/db-old.txt" | sed 's/ $//'); all time: $(totals "$work/stats-old.json")"

  # A returning user: the welcome window was seen. Sparkle's settings are the app's own.
  defaults write "$bundle_id" welcomeShown -bool true
  open "$app"
  old_pid="$(wait_for_pid 10)" || fail "$old_tag did not start"
  note "$old_tag running as $old_pid; waiting for Sparkle"
  began=$SECONDS
  while :; do
    current="$(plist_get "$app" CFBundleVersion 2> /dev/null || true)"
    [ "$current" = "$build" ] && break
    if [ $((SECONDS - began)) -ge 300 ]; then
      log show --last 6m --style compact --info \
        --predicate 'subsystem BEGINSWITH "org.sparkle-project" OR process IN {"Tonearm", "Autoupdate", "Updater"}' \
        > "$out/update-system.log" 2>&1 || true
      tail -n 60 "$out/update-system.log"
      fail "no update after 300 s; installed build is '$current'"
    fi
    sleep 2
  done
  note "bundle became build $build after $((SECONDS - began)) s"
  new_pid="$(wait_for_pid 60 "$old_pid")" || fail "the new version was not relaunched within 60 s"
  ! kill -0 "$old_pid" 2> /dev/null || fail "$old_tag ($old_pid) is still running"
  running="$(ps -o comm= -p "$new_pid")"
  [ "$running" = "$bin" ] || fail "the relaunched process runs $running, not $bin"
  answers="$("$src/scripts/ping-app.sh" "$new_pid" 10)" || fail "the updated app exited or hung"
  note "relaunched as $new_pid: $answers"
  log show --last 10m --style compact --info \
    --predicate 'subsystem BEGINSWITH "org.sparkle-project" OR process IN {"Tonearm", "Autoupdate", "Updater"}' \
    > "$out/update-system.log" 2>&1 || true
  quit_tonearm || fail "the updated app did not quit on request"
  check_bundle "$app" "$version" "$build"
  new_sha="$(binary_sha "$app")"
  [ "$new_sha" != "$old_sha" ] || fail "the binary did not change"
  [ "$new_sha" = "$(state dmg_sha)" ] || fail "the updated binary differs from v$version's DMG"
  note "installed: $(plist_get "$app" CFBundleShortVersionString) ($(plist_get "$app" CFBundleVersion)), binary identical to the DMG's, check-app.sh ok, quarantine: $(quarantine_of "$app")"

  # The history the old release wrote, read by the new one after it ran.
  "$bin" --stats - --db "$db" --json --tz UTC --period all > "$work/stats-new.json" \
    || fail "v$version could not read the history $old_tag wrote"
  python3 -I - "$db" > "$work/db-new.txt" << 'PY'
import sqlite3, sys
c = sqlite3.connect("file:" + sys.argv[1] + "?mode=ro", uri=True)
print("user_version", c.execute("pragma user_version").fetchone()[0])
for (t,) in c.execute("select name from sqlite_master where type = 'table' and name not like 'sqlite_%' order by name"):
    print(t, c.execute('select count(*) from "%s"' % t).fetchone()[0])
PY
  cp "$work/stats-old.json" "$work/stats-new.json" "$work/db-old.txt" "$work/db-new.txt" "$out/"
  python3 -I - "$work/stats-old.json" "$work/stats-new.json" << 'PY' || fail "all-time stats changed across the update"
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
if a != b:
    keys = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
    print("stats differ in:", ", ".join(keys), file=sys.stderr)
    sys.exit(1)
PY
  listens_old="$(awk '$1 == "listens" {print $2}' "$work/db-old.txt")"
  listens_new="$(awk '$1 == "listens" {print $2}' "$work/db-new.txt")"
  [ -n "$listens_old" ] || fail "no listens table in the $old_tag history: $(tr '\n' ' ' < "$work/db-old.txt")"
  [ "$listens_old" = "$listens_new" ] || fail "listens: $listens_old before the update, $listens_new after"
  note "history after update: $(tr '\n' ' ' < "$work/db-new.txt" | sed 's/ $//'); all time: $(totals "$work/stats-new.json"), identical JSON"
  ;;

zap)
  [ -d "$history_dir" ] || fail "no history to remove; the update step failed"
  brew list --cask tonearm > /dev/null || fail "the tonearm cask is not installed"
  # Tonearm running, as it usually is when someone uninstalls it.
  open "$app"
  wait_for_pid 10 > /dev/null || fail "Tonearm did not start before the uninstall"
  brew uninstall --zap --cask tonearm 2>&1 | tee "$out/brew-zap.log"
  [ "${PIPESTATUS[0]}" = 0 ] || fail "brew uninstall --zap --cask tonearm failed"
  for _ in $(seq 1 50); do pgrep -x Tonearm > /dev/null || break; sleep 0.2; done
  ! pgrep -x Tonearm > /dev/null || fail "Tonearm still runs after the uninstall"
  [ ! -e "$app" ] || fail "$app is still there"
  [ ! -e "$history_dir" ] || fail "the history folder is still there: $(ls -la "$history_dir")"
  for p in "$HOME/Library/Preferences/$bundle_id.plist" "$HOME/Library/Caches/$bundle_id" \
           "$HOME/Library/HTTPStorages/$bundle_id" "$HOME/Library/Application Support/$bundle_id"; do
    [ ! -e "$p" ] || fail "$p is still there"
  done
  ! brew list --cask tonearm > /dev/null 2>&1 || fail "brew still lists the cask"
  note "app, history folder, settings, caches gone; Tonearm quit; cask removed"
  ;;

summary)
  [ -f "$results" ] || { echo "no results"; exit 1; }
  {
    echo "| Step | Result | Details |"
    echo "|---|---|---|"
    while IFS=$'\t' read -r step verdict details; do
      printf '| %s | %s | %s |\n' "$step" "$verdict" "${details//|/\\|}"
    done < "$results"
  } | tee -a "${GITHUB_STEP_SUMMARY:-/dev/null}"
  ! grep -q $'\tFAIL\t' "$results"
  ;;

*) fail "unknown step $cmd" ;;
esac
