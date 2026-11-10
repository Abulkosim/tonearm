#!/usr/bin/env bash
# Checks a built Tonearm.app: bundle layout, Sparkle.framework, signatures,
# entitlements, architectures, and that it launches on arm64 and (with Rosetta)
# x86_64, which proves dyld finds Sparkle.
# Usage: scripts/check-app.sh <Tonearm.app>
#
# Environment (all optional):
#   EXPECT_VERSION  CFBundleShortVersionString
#   EXPECT_BUILD    CFBundleVersion
#   EXPECT_SIGNING  adhoc, self-signed or developer-id
set -euo pipefail

app="${1:?usage: check-app.sh <Tonearm.app>}"
fw="$app/Contents/Frameworks/Sparkle.framework"
bin="$app/Contents/MacOS/Tonearm"
plist="$app/Contents/Info.plist"
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

# Info.plist
for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks SUScheduledCheckInterval; do
  "$plistbuddy" -c "Print :$key" "$plist" > /dev/null || fail "Info.plist has no $key"
done
version="$("$plistbuddy" -c 'Print :CFBundleShortVersionString' "$plist")"
build="$("$plistbuddy" -c 'Print :CFBundleVersion' "$plist")"
[ -z "${EXPECT_VERSION:-}" ] || [ "$version" = "$EXPECT_VERSION" ] || fail "version $version, expected $EXPECT_VERSION"
[ -z "${EXPECT_BUILD:-}" ] || [ "$build" = "$EXPECT_BUILD" ] || fail "build $build, expected $EXPECT_BUILD"

# Architectures
for f in "$bin" "$fw/Versions/$fw_version/Sparkle"; do
  archs="$(lipo -archs "$f")"
  [[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || fail "$f is $archs, not universal"
done

# Signatures
codesign --verify --deep --strict --verbose=2 "$app"
codesign -dv --entitlements - "$app" > "$work/app.txt" 2>&1
grep -q 'com.apple.security.automation.apple-events' "$work/app.txt" || fail "no Apple Events entitlement"
grep -Eq 'flags=0x[0-9a-f]+\(.*runtime' "$work/app.txt" || fail "no hardened runtime"
codesign -dv "$fw" > "$work/fw.txt" 2>&1
grep -Eq 'flags=0x[0-9a-f]+\(.*runtime' "$work/fw.txt" || fail "Sparkle.framework has no hardened runtime"
app_authority="$(grep '^Authority=' "$work/app.txt" | head -n 1 || true)"
fw_authority="$(grep '^Authority=' "$work/fw.txt" | head -n 1 || true)"
[ "$app_authority" = "$fw_authority" ] || fail "app ($app_authority) and Sparkle ($fw_authority) are signed differently"
requirement="$(codesign -d -r- "$app" 2>&1 | grep 'designated' || true)"
echo "$requirement"
case "${EXPECT_SIGNING:-}" in
  adhoc)
    grep -q 'Signature=adhoc' "$work/app.txt" || fail "expected an ad-hoc signature" ;;
  self-signed)
    [ "$app_authority" = "Authority=Tonearm Self-Signed" ] || fail "expected Tonearm Self-Signed, got $app_authority"
    # Stable across builds: bundle id plus the certificate, no cdhash.
    [[ "$requirement" == *'identifier "io.github.abulkosim.tonearm"'* && "$requirement" == *'certificate '*'H"'* ]] \
      || fail "designated requirement is not tied to the certificate" ;;
  developer-id)
    [[ "$app_authority" == "Authority=Developer ID Application:"* ]] || fail "expected a Developer ID, got $app_authority" ;;
  "") ;;
  *) fail "unknown EXPECT_SIGNING ${EXPECT_SIGNING}" ;;
esac

# Launch: --snapshot renders PNGs and exits. dyld must load Sparkle first.
"$bin" --snapshot "$work/arm64" > /dev/null
[ -s "$work/arm64/settings.png" ] || fail "arm64 launch rendered nothing"
if [ "$(uname -m)" = arm64 ] && arch -x86_64 /usr/bin/true 2> /dev/null; then
  arch -x86_64 "$bin" --snapshot "$work/x86_64" > /dev/null
  [ -s "$work/x86_64/settings.png" ] || fail "x86_64 launch rendered nothing"
  launched="arm64 and x86_64"
else
  echo "::warning::Rosetta is not available; launched $(uname -m) only"
  launched="$(uname -m)"
fi
echo "app ok: $version ($build), Sparkle $("$plistbuddy" -c 'Print :CFBundleShortVersionString' "$fw/Resources/Info.plist"), ${app_authority:-unsigned}, launched on $launched"
