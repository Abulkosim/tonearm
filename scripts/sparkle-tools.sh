#!/usr/bin/env bash
# Downloads Sparkle's command line tools (sign_update, generate_keys) for the
# version pinned in Package.swift and checks the tarball's SHA-256.
# Usage: scripts/sparkle-tools.sh <dest dir>   -> <dest>/bin/sign_update
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION=2.10.1
# sha256 of Sparkle-2.10.1.tar.xz, matches the digest GitHub shows for the release asset.
SPARKLE_SHA256=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27

dest="${1:?usage: sparkle-tools.sh <dest dir>}"
pinned="$(sed -n 's:.*sparkle-project/Sparkle", exact\: "\([^"]*\)".*:\1:p' Package.swift)"
if [ "$pinned" != "$SPARKLE_VERSION" ]; then
  echo "Package.swift pins Sparkle $pinned but this script downloads $SPARKLE_VERSION; update both" >&2
  exit 1
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
tarball="$work/Sparkle-$SPARKLE_VERSION.tar.xz"
curl -fsSL --retry 3 -o "$tarball" \
  "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
echo "$SPARKLE_SHA256  $tarball" | shasum -a 256 -c -

mkdir -p "$dest"
tar -xJf "$tarball" -C "$dest" ./bin/sign_update ./bin/generate_keys
"$dest/bin/sign_update" --help > /dev/null
echo "Sparkle $SPARKLE_VERSION tools in $dest/bin"
