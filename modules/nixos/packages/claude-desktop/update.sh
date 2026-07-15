#!/usr/bin/env bash
# Bump the pinned claude-desktop: ./update.sh [version]
# No argument = newest version in Anthropic's apt repo index.
# Rewrites the version in flake.nix (input URL) + package.nix, then relocks.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FLAKE_ROOT="$(git rev-parse --show-toplevel)"

BASE_URL="https://downloads.claude.ai/claude-desktop/apt/stable"
VERSION="${1:-$(curl -fsSL "$BASE_URL/dists/stable/main/binary-amd64/Packages" \
  | grep '^Version:' | cut -d' ' -f2 | sort -V | tail -n 1)}"

sed -i -E "s|(claude-desktop_)[0-9]+(\.[0-9]+)*(_amd64\.deb)|\1$VERSION\3|" "$FLAKE_ROOT/flake.nix"
sed -i -E "s|(version = \")[0-9]+(\.[0-9]+)*(\";)|\1$VERSION\3|" package.nix
nix flake update claude-desktop-bin --flake "$FLAKE_ROOT"
echo "pinned claude-desktop $VERSION -- rebuild to apply"
