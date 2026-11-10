#!/usr/bin/env bash
# Writes a Sparkle appcast for one release and signs the update zip with EdDSA.
# Usage: scripts/appcast.sh <update zip> <output appcast.xml>
#
# Environment:
#   VERSION                 X.Y.Z, shown to users (sparkle:shortVersionString)
#   BUILD                   CFBundleVersion of the app in the zip (sparkle:version)
#   TAG                     vX.Y.Z
#   NOTES_FILE              release notes. Default: changelogs/$TAG.md, if it exists
#   REPO                    owner/name on GitHub
#   SPARKLE_ED_PRIVATE_KEY  base64 of the 32-byte ed25519 seed (generate_keys -x)
#   SPARKLE_PUBLIC_KEY      SUPublicEDKey the app ships with; the private key must match it
#   SIGN_UPDATE             path to Sparkle's sign_update (scripts/sparkle-tools.sh)
#   OPENSSL                 an OpenSSL 3 binary. Default: openssl
set -euo pipefail
cd "$(dirname "$0")/.."

zip="${1:?usage: appcast.sh <update zip> <output appcast.xml>}"
out="${2:?usage: appcast.sh <update zip> <output appcast.xml>}"
: "${VERSION:?}" "${BUILD:?}" "${TAG:?}" "${REPO:?}" "${SIGN_UPDATE:?}"
: "${SPARKLE_ED_PRIVATE_KEY:?}" "${SPARKLE_PUBLIC_KEY:?}"
openssl="${OPENSSL:-openssl}"
fail() { echo "appcast: $*" >&2; exit 1; }

# Never echo the key: sign_update prints undecodable input in its error message.
seed_bytes="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | base64 --decode 2>/dev/null | wc -c | tr -d ' ')" || true
[ "$seed_bytes" = 32 ] || fail "SPARKLE_ED_PRIVATE_KEY must be base64 of a 32-byte ed25519 seed"
derived="$(SEED="$SPARKLE_ED_PRIVATE_KEY" OPENSSL="$openssl" scripts/ed25519-public-key.sh)"
[ "$derived" = "$SPARKLE_PUBLIC_KEY" ] \
  || fail "SPARKLE_ED_PRIVATE_KEY does not match the public key $SPARKLE_PUBLIC_KEY"

signature="$(printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - -p "$zip")"
[ -n "$signature" ] || fail "sign_update printed no signature"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$SIGN_UPDATE" --ed-key-file - --verify "$zip" "$signature" \
  || fail "sign_update --verify rejected the signature"
length="$(wc -c < "$zip" | tr -d ' ')"
name="$(basename "$zip")"
url="https://github.com/$REPO/releases/download/$TAG/$name"
release_page="https://github.com/$REPO/releases/tag/$TAG"
pub_date="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"

# Release notes: the changelog bullets, without the "# vX.Y.Z" title and the date line.
notes=""
notes_file="${NOTES_FILE:-changelogs/$TAG.md}"
if [ -f "$notes_file" ]; then
  notes="$(tail -n +2 "$notes_file" | { grep -Ev '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' || true; } | sed '/./,$!d')"
fi
[ -n "$notes" ] || notes="See the [release notes]($release_page)."
[[ "$notes" != *"]]>"* ]] || fail "release notes contain ]]>"

mkdir -p "$(dirname "$out")"
cat > "$out" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Tonearm</title>
    <link>https://github.com/$REPO</link>
    <description>Tonearm updates</description>
    <language>en</language>
    <item>
      <title>Tonearm $VERSION</title>
      <pubDate>$pub_date</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases</sparkle:fullReleaseNotesLink>
      <description sparkle:format="markdown"><![CDATA[
$notes
]]></description>
      <enclosure url="$url" length="$length" type="application/octet-stream" sparkle:edSignature="$signature"/>
    </item>
  </channel>
</rss>
XML

# Check the result with an independent ed25519 implementation and the app's public key.
OPENSSL="$openssl" scripts/verify-appcast.sh "$out" "$zip" "$SPARKLE_PUBLIC_KEY"
