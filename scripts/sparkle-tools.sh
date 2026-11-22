#!/usr/bin/env bash
# Copies Sparkle's command line tools (sign_update, generate_keys) for the Sparkle version
# in Package.resolved into <dest>/bin.
#
# They come from the same archive SwiftPM downloads for the app: Sparkle's
# Sparkle-for-Swift-Package-Manager.zip holds bin/ next to Sparkle.xcframework. SwiftPM checks
# that zip against the checksum in Sparkle's Package.swift, at the commit Package.resolved
# pins. So the tools always match the framework in the app, and a Sparkle bump (by hand or by
# Dependabot) needs no second edit here.
#
# Needs a Swift toolchain (Xcode or the Command Line Tools). Usage:
#   scripts/sparkle-tools.sh <dest dir>   -> <dest>/bin/sign_update, <dest>/bin/generate_keys
set -euo pipefail
cd "$(dirname "$0")/.."

dest="${1:?usage: sparkle-tools.sh <dest dir>}"
fail() { echo "sparkle-tools: $*" >&2; exit 1; }

# The pin in Package.resolved, as {"identity": "sparkle", ..., "state": {"version": "X"}}.
version="$(python3 -I -c 'import json, sys
pins = [p for p in json.load(open(sys.argv[1]))["pins"] if p["identity"] == "sparkle"]
print(pins[0]["state"]["version"] if len(pins) == 1 else "")' Package.resolved)"
[ -n "$version" ] || fail "no Sparkle pin in Package.resolved"

swift package resolve > /dev/null
dir=.build/artifacts/sparkle/Sparkle
for tool in sign_update generate_keys; do
  [ -x "$dir/bin/$tool" ] || fail "$dir/bin/$tool is missing; has Sparkle's SwiftPM archive changed?"
done
framework="$(find "$dir" -type d -path '*/Sparkle.xcframework/macos-*/Sparkle.framework' -prune | head -n 1)"
[ -n "$framework" ] || fail "Sparkle.framework not found under $dir"
built="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$framework/Resources/Info.plist")"
[ "$built" = "$version" ] || fail "Package.resolved pins Sparkle $version, but SwiftPM fetched $built"

mkdir -p "$dest/bin"
cp "$dir/bin/sign_update" "$dir/bin/generate_keys" "$dest/bin/"
"$dest/bin/sign_update" --help > /dev/null
echo "Sparkle $version tools in $dest/bin"
