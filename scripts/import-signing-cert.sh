#!/usr/bin/env bash
# Imports the Developer ID certificate into a temporary keychain for codesign.
# CI only. Remove it afterwards with: security delete-keychain "$RUNNER_TEMP/tonearm-signing.keychain-db"
#
# Environment: MACOS_CERT_P12 (base64 of the .p12), MACOS_CERT_PASSWORD, MACOS_SIGN_IDENTITY, RUNNER_TEMP
set -euo pipefail

: "${MACOS_CERT_P12:?}" "${MACOS_CERT_PASSWORD:?}" "${MACOS_SIGN_IDENTITY:?}" "${RUNNER_TEMP:?}"
keychain="$RUNNER_TEMP/tonearm-signing.keychain-db"
cert="$RUNNER_TEMP/tonearm-signing.p12"
password="$(openssl rand -base64 24)"
trap 'rm -f "$cert"' EXIT

printf '%s' "$MACOS_CERT_P12" | base64 --decode > "$cert"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$cert" -k "$keychain" -P "$MACOS_CERT_PASSWORD" -f pkcs12 -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" > /dev/null

# Put the temporary keychain first in the search list, keeping the others.
existing=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  existing+=("${line//\"/}")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" "${existing[@]}"

if ! security find-identity -v -p codesigning "$keychain" | grep -qF "\"$MACOS_SIGN_IDENTITY\""; then
  echo "identity \"$MACOS_SIGN_IDENTITY\" not found in the imported certificate" >&2
  security find-identity -v -p codesigning "$keychain" >&2
  exit 1
fi
echo "imported signing identity"
