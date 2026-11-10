#!/usr/bin/env bash
# Prints the base64 ed25519 public key (the SUPublicEDKey format) for a private seed.
# Environment: SEED (base64 of the 32-byte seed), OPENSSL (an OpenSSL 3 binary, default openssl)
set -euo pipefail

: "${SEED:?}"
openssl="${OPENSSL:-openssl}"
# PKCS#8 header for an Ed25519 private key; the 32-byte seed follows.
{ printf '302e020100300506032b657004220420' | xxd -r -p; printf '%s' "$SEED" | base64 --decode; } \
  | "$openssl" pkey -inform DER -pubout -outform DER \
  | tail -c 32 | base64
