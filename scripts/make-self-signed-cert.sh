#!/usr/bin/env bash
# Makes the "Tonearm Self-Signed" code signing certificate as a .p12 that
# `security import` accepts (legacy PBE-SHA1-3DES encryption, SHA-1 MAC).
# The release workflow imports it from the SELF_SIGN_CERT_P12 secret.
#
# Keep the .p12 forever: macOS ties the Automation permission and Sparkle ties
# updates to this exact certificate. A new one costs every user one more prompt.
#
# Usage: P12_PASSWORD=... scripts/make-self-signed-cert.sh <output dir>
# Writes <dir>/tonearm-self-signed.p12 and <dir>/tonearm-self-signed.pem (public cert).
set -euo pipefail

out="${1:?usage: P12_PASSWORD=... make-self-signed-cert.sh <output dir>}"
: "${P12_PASSWORD:?set P12_PASSWORD}"
name="Tonearm Self-Signed"
mkdir -p "$out"
umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/req.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

# 20 years. Ad-hoc-free updates depend on this certificate, so it should outlive the app.
openssl req -x509 -new -newkey rsa:2048 -sha256 -days 7300 -nodes \
  -config "$work/req.cnf" -keyout "$work/key.pem" -out "$out/tonearm-self-signed.pem"
openssl pkcs12 -export -name "$name" \
  -inkey "$work/key.pem" -in "$out/tonearm-self-signed.pem" \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
  -passout env:P12_PASSWORD -out "$out/tonearm-self-signed.p12"
openssl x509 -in "$out/tonearm-self-signed.pem" -noout -subject -enddate -fingerprint -sha256
echo "wrote $out/tonearm-self-signed.p12"
