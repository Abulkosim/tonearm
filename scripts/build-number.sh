#!/usr/bin/env bash
# Prints the CFBundleVersion for a version: major*10000 + minor*100 + patch.
# 0.3.0 -> 300, 1.2.3 -> 10203. A pre-release suffix is ignored (0.0.0-test -> 0).
# Sparkle compares this number to decide what is newer, so it must grow with every
# release; minor and patch therefore stay below 100.
# Usage: scripts/build-number.sh X.Y.Z[-suffix]
set -euo pipefail

version="${1:?usage: build-number.sh X.Y.Z}"
core="${version%%-*}"
if [[ ! "$core" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "build-number: $version is not X.Y.Z" >&2
  exit 1
fi
major=$((10#${BASH_REMATCH[1]})) minor=$((10#${BASH_REMATCH[2]})) patch=$((10#${BASH_REMATCH[3]}))
if [ "$minor" -ge 100 ] || [ "$patch" -ge 100 ]; then
  echo "build-number: minor and patch must be below 100, got $version" >&2
  exit 1
fi
echo $((major * 10000 + minor * 100 + patch))
