#!/usr/bin/env bash
# Checks a built Tonearm.app against the rules a real Mac applies, so a bundle that
# would not start for users fails here even though it starts on a CI runner:
#
# - every Mach-O in the bundle is signed, the signatures verify (--strict), and each
#   designated requirement is the one its signing mode should produce;
# - library validation: a hardened executable without the disable-library-validation
#   entitlement only loads libraries with its own, non-empty Team ID. CI runners don't
#   enforce this; real Macs do. v0.3.0 died on it ("different Team IDs");
# - entitlements are exactly Resources/Tonearm.entitlements;
# - Info.plist equals Resources/Info.plist except the version and build, has the keys Sparkle
#   needs, and the minimum macOS is 13.0, in Info.plist and in every Mach-O;
# - both architectures, then a launch on arm64 and (with Rosetta) x86_64.
#
# Usage: scripts/check-app.sh <Tonearm.app>
#
# Environment (all optional):
#   EXPECT_VERSION   CFBundleShortVersionString
#   EXPECT_BUILD     CFBundleVersion
#   EXPECT_SIGNING   adhoc, self-signed or developer-id
#   EXPECT_FEED_URL  SUFeedURL. Default: the value in Resources/Info.plist
#   EXPECT_ED_KEY    SUPublicEDKey. Default: the value in Resources/Info.plist
#   SKIP_LAUNCH      1 skips the launch, for bundles from elsewhere
set -euo pipefail

app="${1:?usage: check-app.sh <Tonearm.app>}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
fw="$app/Contents/Frameworks/Sparkle.framework"
bin="$app/Contents/MacOS/Tonearm"
plist="$app/Contents/Info.plist"
bundle_id=io.github.abulkosim.tonearm
plistbuddy=/usr/libexec/PlistBuddy
fail() { echo "check-app: $*" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Layout
[ -L "$fw/Versions/Current" ] || fail "Sparkle.framework lost its Versions/Current symlink"
[ -L "$fw/Sparkle" ] || fail "Sparkle.framework lost its top-level symlinks"
fw_version="$(readlink "$fw/Versions/Current")"
for f in "$fw/Versions/$fw_version/Sparkle" "$fw/Versions/$fw_version/Autoupdate" \
         "$fw/Versions/$fw_version/Updater.app"; do
  [ -e "$f" ] || fail "missing $f"
done
[ ! -e "$fw/Versions/$fw_version/XPCServices" ] || fail "Sparkle XPC services should be removed"
otool -L "$bin" > "$work/libs"
grep -qF '@rpath/Sparkle.framework/Versions/' "$work/libs" || fail "Tonearm does not link Sparkle"

# Every Mach-O in the bundle, main binary first. find does not follow the framework's symlinks.
machos=("$bin")
while IFS= read -r -d '' f; do
  [ "$f" = "$bin" ] && continue
  if file -b "$f" | grep -q 'Mach-O'; then machos+=("$f"); fi
done < <(find "$app" -type f -print0 | sort -z)
[ "${#machos[@]}" -ge 4 ] || fail "expected at least 4 Mach-O files (app, Sparkle, Autoupdate, Updater), found ${#machos[@]}"

# Signatures: the whole bundle, then each Mach-O on its own.
codesign --verify --deep --strict --verbose=2 "$app"
# Prints: team (or -), runtime (yes/no), disable-library-validation (yes/no), dylib (yes/no),
# ad-hoc (yes/no), first authority (or -), designated requirement.
describe() {
  local f="$1" info ents req
  codesign --verify --strict "$f" 2> "$work/verify" || fail "signature of $f does not verify: $(cat "$work/verify")"
  info="$(codesign -dvv "$f" 2>&1)"
  ents="$(codesign -d --entitlements - --xml "$f" 2> /dev/null || true)"
  # Ad-hoc signatures print an implicit requirement as "# designated => cdhash ...".
  req="$(codesign -d -r- "$f" 2>&1 | sed -n 's/^#* *designated => //p')"
  local team runtime dlv dylib adhoc authority
  team="$(sed -n 's/^TeamIdentifier=//p' <<< "$info")"
  case "$team" in ""|"not set") team=- ;; esac
  runtime=no; grep -Eq '^CodeDirectory .*flags=0x[0-9a-f]+\([^)]*runtime' <<< "$info" && runtime=yes
  dlv="$(printf '%s' "$ents" | python3 -I -c 'import plistlib, sys
data = sys.stdin.buffer.read()
ents = plistlib.loads(data) if data.strip() else {}
print("yes" if ents.get("com.apple.security.cs.disable-library-validation") is True else "no")')"
  dylib=no; otool -hv -arch all "$f" | grep -Eq ' (DYLIB|BUNDLE) ' && dylib=yes
  adhoc=no; grep -q '^Signature=adhoc' <<< "$info" && adhoc=yes
  authority="$(sed -n 's/^Authority=//p' <<< "$info" | head -n 1)"
  printf '%s\n' "$team" "$runtime" "$dlv" "$dylib" "$adhoc" "${authority:--}" "${req:--}"
}
n=0
for f in "${machos[@]}"; do
  describe "$f" > "$work/sig.$n"
  n=$((n + 1))
done
field() { sed -n "$2p" "$work/sig.$1"; } # index, line
rel() { echo "${1#"$app/"}"; }

# Library validation, the rule that stopped v0.3.0 on real Macs.
for i in "${!machos[@]}"; do
  [ "$(field "$i" 2)" = yes ] || continue  # no hardened runtime, no library validation
  [ "$(field "$i" 3)" = no ] || continue   # disable-library-validation entitlement
  [ "$(field "$i" 4)" = no ] || continue   # libraries are checked by whoever loads them
  team="$(field "$i" 1)"
  exe="$(rel "${machos[$i]}")"
  [ "$team" != - ] || fail "library validation: $exe has the hardened runtime but no Team ID, so macOS refuses every library not signed by Apple (\"different Team IDs\"). Sign with a Developer ID, or without --options runtime."
  for j in "${!machos[@]}"; do
    [ "$(field "$j" 4)" = yes ] || continue
    [ "$(field "$j" 1)" = "$team" ] \
      || fail "library validation: $exe (Team ID $team) would load $(rel "${machos[$j]}") (Team ID $(field "$j" 1)); macOS refuses it (\"different Team IDs\")."
  done
done

# Everything is signed the same way as the app.
app_authority="$(field 0 6)"
app_requirement="$(field 0 7)"
app_team="$(field 0 1)"
echo "designated => $app_requirement"
[[ "$app_requirement" == *"identifier \"$bundle_id\""* || "$app_requirement" == cdhash* ]] \
  || fail "designated requirement does not name $bundle_id: $app_requirement"
for i in "${!machos[@]}"; do
  [ "$(field "$i" 6)" = "$app_authority" ] \
    || fail "$(rel "${machos[$i]}") is signed by $(field "$i" 6), the app by $app_authority"
  [ "$(field "$i" 1)" = "$app_team" ] || fail "$(rel "${machos[$i]}") has Team ID $(field "$i" 1), the app $app_team"
  [ "$(field "$i" 5)" = "$(field 0 5)" ] || fail "$(rel "${machos[$i]}") and the app disagree on ad-hoc signing"
  req="$(field "$i" 7)"
  if [ "$(field "$i" 5)" = yes ]; then
    [[ "$req" == cdhash* ]] || fail "ad-hoc $(rel "${machos[$i]}") has designated requirement $req"
  else
    # Tied to the same certificate as the app: the same certificate hash or the same team.
    app_certs="$(grep -Eo 'H"[0-9a-f]+"|subject\.OU\] = [^ )]+' <<< "$app_requirement" | sort -u)"
    certs="$(grep -Eo 'H"[0-9a-f]+"|subject\.OU\] = [^ )]+' <<< "$req" | sort -u)"
    if [ -z "$certs" ] || [ "$certs" != "$app_certs" ]; then
      fail "$(rel "${machos[$i]}") has designated requirement $req, not tied to the app's certificate"
    fi
  fi
done
echo "signatures: ${#machos[@]} Mach-O files, signed alike, library validation ok"

# Entitlements: exactly the file.
codesign -d --entitlements - --xml "$app" > "$work/entitlements.plist" 2> /dev/null || true
python3 -I - "$work/entitlements.plist" "$repo/Resources/Tonearm.entitlements" <<'PY' || fail "entitlements differ from Resources/Tonearm.entitlements"
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    data = f.read()
got = plistlib.loads(data) if data.strip() else {}
with open(sys.argv[2], "rb") as f:
    want = plistlib.load(f)
if got != want:
    print(f"signed with {got}, expected {want}", file=sys.stderr)
    sys.exit(1)
PY

# Hardened runtime: Developer ID builds need it for notarization. Others must not have it
# (library validation above explains why; this names the cause).
for i in "${!machos[@]}"; do
  if [ "$(field "$i" 2)" = yes ]; then
    [ "${EXPECT_SIGNING:-}" = developer-id ] || fail "$(rel "${machos[$i]}") has the hardened runtime without a Developer ID"
  else
    [ "${EXPECT_SIGNING:-}" != developer-id ] || fail "$(rel "${machos[$i]}") has no hardened runtime"
  fi
done
case "${EXPECT_SIGNING:-}" in
  adhoc)
    [ "$(field 0 5)" = yes ] || fail "expected an ad-hoc signature" ;;
  self-signed)
    [ "$app_authority" = "Tonearm Self-Signed" ] || fail "expected Tonearm Self-Signed, got $app_authority"
    # Stable across builds: bundle id plus the certificate, no cdhash.
    [[ "$app_requirement" == *"identifier \"$bundle_id\""* && "$app_requirement" == *'certificate '*'H"'* ]] \
      || fail "designated requirement is not tied to the certificate" ;;
  developer-id)
    [[ "$app_authority" == "Developer ID Application:"* ]] || fail "expected a Developer ID, got $app_authority"
    [[ "$app_team" =~ ^[A-Z0-9]{10}$ ]] || fail "a Developer ID build should have a 10-character Team ID, got $app_team"
    # codesign quotes a Team ID that starts with a digit ("9ABCDE1234"), not one that starts with a letter.
    team_ou="subject\.OU\] = \"?$app_team\"?([ )]|$)"
    [[ "$app_requirement" == *"anchor apple generic"* && "$app_requirement" =~ $team_ou ]] \
      || fail "designated requirement is not tied to Team ID $app_team" ;;
  "") ;;
  *) fail "unknown EXPECT_SIGNING ${EXPECT_SIGNING}" ;;
esac

# Info.plist: the source file with the version and build set, nothing else changed.
python3 -I - "$plist" "$repo/Resources/Info.plist" <<'PY' || fail "Info.plist is wrong"
import base64, binascii, os, plistlib, sys
with open(sys.argv[1], "rb") as f:
    built = plistlib.load(f)
with open(sys.argv[2], "rb") as f:
    source = plistlib.load(f)
expected = dict(source)
for key, env in (("SUFeedURL", "EXPECT_FEED_URL"), ("SUPublicEDKey", "EXPECT_ED_KEY")):
    if os.environ.get(env):
        expected[key] = os.environ[env]
errors = []
for key in sorted(set(built) | set(expected)):
    if key in ("CFBundleShortVersionString", "CFBundleVersion"):
        continue
    if built.get(key) != expected.get(key):
        errors.append(f"{key} is {built.get(key)!r}, expected {expected.get(key)!r}")
for key in ("SUFeedURL", "SUPublicEDKey", "SUEnableAutomaticChecks", "SUScheduledCheckInterval",
            "CFBundleShortVersionString", "CFBundleVersion"):
    if key not in built:
        errors.append(f"no {key}")
try:
    if len(base64.b64decode(built.get("SUPublicEDKey", ""), validate=True)) != 32:
        errors.append("SUPublicEDKey is not 32 bytes")
except (binascii.Error, TypeError):
    errors.append("SUPublicEDKey is not base64")
if not str(built.get("CFBundleVersion", "")).isdigit():
    errors.append("CFBundleVersion is not a number; Sparkle compares it")
if built.get("LSMinimumSystemVersion") != "13.0":
    errors.append(f"LSMinimumSystemVersion is {built.get('LSMinimumSystemVersion')!r}, expected '13.0'")
if built.get("CFBundleIdentifier") != "io.github.abulkosim.tonearm":
    errors.append(f"CFBundleIdentifier is {built.get('CFBundleIdentifier')!r}")
for e in errors:
    print(f"check-app: Info.plist: {e}", file=sys.stderr)
sys.exit(1 if errors else 0)
PY
version="$("$plistbuddy" -c 'Print :CFBundleShortVersionString' "$plist")"
build="$("$plistbuddy" -c 'Print :CFBundleVersion' "$plist")"
[ -z "${EXPECT_VERSION:-}" ] || [ "$version" = "$EXPECT_VERSION" ] || fail "version $version, expected $EXPECT_VERSION"
[ -z "${EXPECT_BUILD:-}" ] || [ "$build" = "$EXPECT_BUILD" ] || fail "build $build, expected $EXPECT_BUILD"

# Architectures, and the minimum macOS each Mach-O was built for.
for f in "$bin" "$fw/Versions/$fw_version/Sparkle"; do
  archs="$(lipo -archs "$f")"
  [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || fail "$f is $archs, not universal"
done
for f in "${machos[@]}"; do
  minimums="$(otool -l -arch all "$f" | awk '/LC_BUILD_VERSION/ {b = 1} /LC_VERSION_MIN_MACOSX/ {v = 1}
    b && $1 == "minos" {print $2; b = 0} v && $1 == "version" {print $2; v = 0}' | sort -u)"
  [ -n "$minimums" ] || fail "$(rel "$f") has no minimum macOS version"
  for m in $minimums; do
    [ "$(printf '%s\n13.0\n' "$m" | sort -V | tail -n 1)" = 13.0 ] || fail "$(rel "$f") needs macOS $m, newer than 13.0"
  done
  if [ "$f" = "$bin" ] && [ "$minimums" != 13.0 ]; then
    fail "Tonearm is built for macOS $minimums, expected 13.0"
  fi
done

if [ "${SKIP_LAUNCH:-}" = 1 ]; then
  echo "app ok (not launched): $version ($build), signed by $app_authority"
  exit 0
fi

# Launch: --snapshot renders PNGs and exits. dyld must load Sparkle first. An Intel Mac
# runs the x86_64 slice natively and can't run arm64.
host="$(uname -m)"
"$bin" --snapshot "$work/$host" > /dev/null
[ -s "$work/$host/settings.png" ] || fail "$host launch rendered nothing"
if [ "$host" = x86_64 ]; then
  launched="x86_64 (an Intel runner)"
elif arch -x86_64 /usr/bin/true 2> /dev/null; then
  arch -x86_64 "$bin" --snapshot "$work/x86_64" > /dev/null
  [ -s "$work/x86_64/settings.png" ] || fail "x86_64 launch rendered nothing"
  launched="arm64 and x86_64"
else
  echo "::warning::Rosetta is not available; launched $(uname -m) only"
  launched="$(uname -m)"
fi
signer="$app_authority"
[ "$(field 0 5)" = yes ] && signer=ad-hoc
echo "app ok: $version ($build), Sparkle $("$plistbuddy" -c 'Print :CFBundleShortVersionString' "$fw/Resources/Info.plist"), signed by $signer, launched on $launched"
