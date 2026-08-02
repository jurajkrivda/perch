#!/usr/bin/env bash
set -euo pipefail

# Ensures the pinned Sparkle command-line tools (generate_appcast,
# generate_keys, sign_update) exist locally and prints the tools directory.
# The version must match the SwiftPM pin in project.yml.

SPARKLE_VERSION="2.9.5"
SPARKLE_SHA256="015336b601493e05c237964954bff6191370003d94edefe663724c88840d73cc"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS_DIR="$ROOT_DIR/build/tools/sparkle-$SPARKLE_VERSION"
TARBALL_URL="https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"

if [[ ! -x "$TOOLS_DIR/bin/generate_appcast" ]]; then
  mkdir -p "$TOOLS_DIR"
  TARBALL="$TOOLS_DIR/Sparkle.tar.xz"
  curl -fsSL "$TARBALL_URL" -o "$TARBALL"
  echo "$SPARKLE_SHA256  $TARBALL" | shasum -a 256 -c - >&2
  tar -xJf "$TARBALL" -C "$TOOLS_DIR"
  rm "$TARBALL"
fi

if [[ ! -x "$TOOLS_DIR/bin/generate_appcast" ]]; then
  echo "error: Sparkle tools missing generate_appcast after extraction" >&2
  exit 1
fi

echo "$TOOLS_DIR"
