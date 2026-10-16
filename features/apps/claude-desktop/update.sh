#!/usr/bin/env bash
# Bump the pinned claude-desktop: ./update.sh [version]
# No argument = newest version in Anthropic's apt repo index.
# Rewrites the version in THIS feature's flake.nix (input URL) + package.nix,
# then relocks both the feature and the root's view of it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FLAKE_ROOT="$(git rev-parse --show-toplevel)"
HERE="$(pwd)"   # this feature's own directory; its flake.nix owns the pin

BASE_URL="https://downloads.claude.ai/claude-desktop/apt/stable"
VERSION="${1:-$(curl -fsSL "$BASE_URL/dists/stable/main/binary-amd64/Packages" \
  | grep '^Version:' | cut -d' ' -f2 | sort -V | tail -n 1)}"

sed -i -E "s|(claude-desktop_)[0-9]+(\.[0-9]+)*(_amd64\.deb)|\1$VERSION\3|" "$HERE/flake.nix"
sed -i -E "s|(version = \")[0-9]+(\.[0-9]+)*(\";)|\1$VERSION\3|" package.nix
# Two locks: this feature's own, then the root's view of it.
nix flake update claude-desktop-bin --flake "$HERE"
nix flake update "feat-$(basename "$HERE")" --flake "$FLAKE_ROOT"
echo "pinned claude-desktop $VERSION -- rebuild to apply"
