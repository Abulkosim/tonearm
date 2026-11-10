#!/usr/bin/env bash
# Imports a code signing certificate into a temporary keychain for codesign.
# CI only. Remove it afterwards with: security delete-keychain "$RUNNER_TEMP/tonearm-signing.keychain-db"
#
# Environment:
#   CERT_P12       base64 of the .p12
#   CERT_PASSWORD  its password
#   CERT_IDENTITY  the certificate's common name, for example "Tonearm Self-Signed"
#   TRUST_CERT     "true" for a self-signed certificate: if codesign refuses it as
#                  untrusted, marks it trusted for code signing (needs sudo).
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

# Signs a scratch copy of a binary with the identity; the real test of whether codesign accepts it.
can_sign() {
  local probe="$RUNNER_TEMP/tonearm-sign-probe"
  cp /usr/bin/true "$probe"
  local ok=0
  codesign --force --sign "$CERT_IDENTITY" --keychain "$keychain" "$probe" 2> "$probe.log" || ok=1
  rm -f "$probe"
  return "$ok"
}

if [ "${TRUST_CERT:-false}" = true ] && ! can_sign; then
  # A self-signed certificate has no chain to Apple, so codesign may refuse it
  # (CSSMERR_TP_NOT_TRUSTED). Trust it for code signing: admin domain with sudo,
  # then the user domain.
  echo "codesign refused the untrusted certificate: $(cat "$RUNNER_TEMP/tonearm-sign-probe.log")"
  security find-certificate -c "$CERT_IDENTITY" -p "$keychain" > "$pem"
  sudo security add-trusted-cert -d -r trustRoot -p codeSign -k "$keychain" "$pem" \
    || security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$pem" \
    || true
fi

if ! can_sign; then
  echo "codesign cannot use \"$CERT_IDENTITY\": $(cat "$RUNNER_TEMP/tonearm-sign-probe.log")" >&2
  security find-identity -p codesigning "$keychain" >&2
  exit 1
fi
rm -f "$RUNNER_TEMP/tonearm-sign-probe.log"
security find-identity -p codesigning "$keychain"
echo "imported signing identity"
