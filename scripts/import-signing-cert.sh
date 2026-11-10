#!/usr/bin/env bash
# Imports a code signing certificate into a temporary keychain for codesign.
# CI only. Remove it afterwards with: security delete-keychain "$RUNNER_TEMP/tonearm-signing.keychain-db"
#
# Environment:
#   CERT_P12       base64 of the .p12
#   CERT_PASSWORD  its password
#   CERT_IDENTITY  the certificate's common name, for example "Tonearm Self-Signed"
#   TRUST_CERT     "true" for a self-signed certificate: marks it trusted for code
#                  signing (needs sudo), so codesign and find-identity accept it.
#   RUNNER_TEMP
set -euo pipefail

: "${CERT_P12:?}" "${CERT_PASSWORD:?}" "${CERT_IDENTITY:?}" "${RUNNER_TEMP:?}"
keychain="$RUNNER_TEMP/tonearm-signing.keychain-db"
cert="$RUNNER_TEMP/tonearm-signing.p12"
pem="$RUNNER_TEMP/tonearm-signing.pem"
password="$(openssl rand -base64 24)"
trap 'rm -f "$cert" "$pem"' EXIT

printf '%s' "$CERT_P12" | base64 --decode > "$cert"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$cert" -k "$keychain" -P "$CERT_PASSWORD" -f pkcs12 -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" > /dev/null

# Put the temporary keychain first in the search list, keeping the others.
existing=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"
  existing+=("${line//\"/}")
done < <(security list-keychains -d user)
security list-keychains -d user -s "$keychain" "${existing[@]}"

if [ "${TRUST_CERT:-false}" = true ]; then
  # A self-signed certificate has no chain to Apple; without this codesign fails
  # with CSSMERR_TP_NOT_TRUSTED. Admin trust settings need sudo; the authorization
  # rule change lets sudo set them without a password dialog on the CI runner.
  security find-certificate -c "$CERT_IDENTITY" -p "$keychain" > "$pem"
  sudo security authorizationdb write com.apple.trust-settings.admin allow > /dev/null
  sudo security add-trusted-cert -d -r trustRoot -p codeSign -p basic \
    -k /Library/Keychains/System.keychain "$pem"
fi

if ! security find-identity -v -p codesigning "$keychain" | grep -qF "\"$CERT_IDENTITY\""; then
  echo "identity \"$CERT_IDENTITY\" not found or not valid in the imported certificate" >&2
  security find-identity -p codesigning "$keychain" >&2
  exit 1
fi
echo "imported signing identity"
