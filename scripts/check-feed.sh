#!/usr/bin/env bash
# Checks the public update feed and download link, as installed copies and new users see them:
# - SUFeedURL (from Resources/Info.plist) answers, and its newest item is the latest GitHub
#   release: version, build number, and the enclosure is that release's zip;
# - the zip's EdDSA signature verifies with SUPublicEDKey, its checksum matches the release's
#   SHA256SUMS.txt, and the app inside carries the same version, feed and key;
# - releases/latest/download/Tonearm.dmg redirects to the latest release's DMG, and the DMG
#   matches SHA256SUMS.txt.
# Usage: scripts/check-feed.sh [owner/repo]
# Needs gh (with GH_TOKEN in CI), curl, python3, xxd and OpenSSL 3 (OPENSSL, default openssl).
set -euo pipefail
cd "$(dirname "$0")/.."

repo="${1:-Abulkosim/tonearm}"
fail() { echo "::error::check-feed: $*" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

plist_value() { # file key
  python3 -I -c 'import plistlib, sys; print(plistlib.load(open(sys.argv[1], "rb"))[sys.argv[2]])' "$1" "$2"
}
feed_url="$(plist_value Resources/Info.plist SUFeedURL)"
public_key="$(plist_value Resources/Info.plist SUPublicEDKey)"
tag="$(gh api "repos/$repo/releases/latest" --jq .tag_name)"
version="${tag#v}"
build="$(scripts/build-number.sh "$version")"
echo "latest release: $tag (build $build)"
echo "feed: $feed_url"

curl -fsSL --retry 3 -o "$work/appcast.xml" "$feed_url" || fail "cannot fetch $feed_url"
# Newest item by sparkle:version: version, short version, enclosure url.
python3 -I - "$work/appcast.xml" > "$work/newest" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(sys.argv[1]).getroot().findall("./channel/item")
if not items:
    sys.exit("the appcast has no items")
def build(item):
    return int((item.findtext(ns + "version") or "0").strip())
item = max(items, key=build)
print(build(item))
print((item.findtext(ns + "shortVersionString") or "").strip())
print(item.find("enclosure").get("url"))
PY
{ read -r feed_build; read -r feed_version; read -r zip_url; } < "$work/newest"
[ "$feed_version" = "$version" ] || fail "the feed's newest item is $feed_version, the latest release is $version"
[ "$feed_build" = "$build" ] || fail "the feed's newest build is $feed_build, expected $build"
expected_zip="https://github.com/$repo/releases/download/$tag/Tonearm-$version.zip"
[ "$zip_url" = "$expected_zip" ] || fail "the enclosure is $zip_url, expected $expected_zip"

curl -fsSL --retry 3 -o "$work/Tonearm-$version.zip" "$zip_url" || fail "cannot download $zip_url"
scripts/verify-appcast.sh "$work/appcast.xml" "$work/Tonearm-$version.zip" "$public_key"

curl -fsSL --retry 3 -o "$work/SHA256SUMS.txt" "https://github.com/$repo/releases/download/$tag/SHA256SUMS.txt"
(cd "$work" && grep -E "  Tonearm-$version\\.zip\$" SHA256SUMS.txt | sha256sum -c -) || fail "the zip does not match SHA256SUMS.txt"

# The app inside the update.
python3 -I - "$work/Tonearm-$version.zip" > "$work/Info.plist" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as z:
    sys.stdout.buffer.write(z.read("Tonearm.app/Contents/Info.plist"))
PY
[ "$(plist_value "$work/Info.plist" CFBundleShortVersionString)" = "$version" ] || fail "the app in the zip is not $version"
[ "$(plist_value "$work/Info.plist" CFBundleVersion)" = "$build" ] || fail "the app in the zip is not build $build"
[ "$(plist_value "$work/Info.plist" SUFeedURL)" = "$feed_url" ] || fail "the app in the zip reads another feed"
[ "$(plist_value "$work/Info.plist" SUPublicEDKey)" = "$public_key" ] || fail "the app in the zip trusts another key"

# The stable DMG link.
dmg_link="https://github.com/$repo/releases/latest/download/Tonearm.dmg"
location="$(curl -fsSI "$dmg_link" | tr -d '\r' | sed -n 's/^[Ll]ocation: //p' | head -n 1)"
[ "$location" = "https://github.com/$repo/releases/download/$tag/Tonearm.dmg" ] \
  || fail "$dmg_link redirects to '$location', not to $tag"
curl -fsSL --retry 3 -o "$work/Tonearm.dmg" "$dmg_link" || fail "cannot download $dmg_link"
(cd "$work" && grep -E '  Tonearm\.dmg$' SHA256SUMS.txt | sha256sum -c -) || fail "Tonearm.dmg does not match SHA256SUMS.txt"

echo "feed ok: $tag ($build), signature verified with $public_key, $dmg_link -> $tag"
