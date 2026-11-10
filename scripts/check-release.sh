#!/usr/bin/env bash
# Checks that a release tag has its release notes and matching version.
# Usage: scripts/check-release.sh vX.Y.Z
set -euo pipefail
cd "$(dirname "$0")/.."

tag="${1:?usage: check-release.sh vX.Y.Z}"
fail() { echo "check-release: $*" >&2; exit 1; }

[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "tag $tag is not vX.Y.Z"
version="${tag#v}"
notes="changelogs/$tag.md"

[ -f "$notes" ] || fail "missing $notes"
[ "$(head -n 1 "$notes")" = "# $tag" ] || fail "$notes must start with '# $tag'"
grep -qF "]($notes)" CHANGELOG.md || fail "CHANGELOG.md has no row linking $notes"

plist_version="$(grep -A1 '<key>CFBundleShortVersionString</key>' Resources/Info.plist \
  | sed -n 's:.*<string>\(.*\)</string>.*:\1:p')"
[ "$plist_version" = "$version" ] \
  || fail "Resources/Info.plist CFBundleShortVersionString is $plist_version, expected $version"

echo "release $tag ok"
