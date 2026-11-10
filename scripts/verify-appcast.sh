#!/usr/bin/env bash
# Checks a Sparkle appcast against its update zip: the enclosure points at the zip,
# the length matches, and the EdDSA signature verifies with the given public key.
# Uses OpenSSL 3, not Sparkle, so it is an independent check.
# Usage: scripts/verify-appcast.sh <appcast.xml> <update zip> <base64 public key>
# Environment: OPENSSL (an OpenSSL 3 binary, default openssl)
set -euo pipefail

appcast="${1:?usage: verify-appcast.sh <appcast.xml> <zip> <public key>}"
zip="${2:?}"
public_key="${3:?}"
openssl="${OPENSSL:-openssl}"
fail() { echo "verify-appcast: $*" >&2; exit 1; }

"$openssl" version | grep -q '^OpenSSL 3' || fail "$openssl is not OpenSSL 3"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Prints url, length, signature, version, short version on separate lines.
python3 -I - "$appcast" > "$work/fields" <<'PY'
import sys
import xml.etree.ElementTree as ET
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
items = ET.parse(sys.argv[1]).getroot().findall("./channel/item")
if len(items) != 1:
    sys.exit(f"expected one item, found {len(items)}")
item = items[0]
enc = item.find("enclosure")
for value in (enc.get("url"), enc.get("length"), enc.get(ns + "edSignature"),
              item.findtext(ns + "version"), item.findtext(ns + "shortVersionString"),
              item.findtext(ns + "minimumSystemVersion")):
    if not value:
        sys.exit("appcast is missing a required field")
    print(value.strip())
PY
{ read -r url; read -r length; read -r signature; read -r version; read -r short; read -r minimum; } < "$work/fields"

[ "$(basename "$url")" = "$(basename "$zip")" ] || fail "enclosure $url is not $(basename "$zip")"
[ "$length" = "$(wc -c < "$zip" | tr -d ' ')" ] || fail "enclosure length $length does not match the zip"
[[ "$version" =~ ^[0-9]+$ ]] || fail "sparkle:version $version is not a number"

{ printf '302a300506032b6570032100' | xxd -r -p; printf '%s' "$public_key" | base64 --decode; } > "$work/pub.der"
printf '%s' "$signature" | base64 --decode > "$work/sig"
"$openssl" pkeyutl -verify -pubin -keyform DER -inkey "$work/pub.der" -rawin \
  -in "$zip" -sigfile "$work/sig" > /dev/null \
  || fail "the EdDSA signature does not verify with $public_key"
echo "appcast ok: $short ($version), macOS $minimum+, $url, signature verified with $public_key"
