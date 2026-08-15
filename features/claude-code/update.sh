#!/usr/bin/env bash
# Bump the pinned claude-code: ./update.sh [version]
# No argument = whatever Anthropic's release channel calls "latest" right now.
# Rewrites the version in THIS feature's flake.nix (input URL) + package.nix,
# then relocks both the feature and the root's view of it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FLAKE_ROOT="$(git rev-parse --show-toplevel)"
HERE="$(pwd)"   # this feature's own directory; its flake.nix owns the pin

BASE_URL="https://downloads.claude.ai/claude-code-releases"
VERSION="${1:-$(curl -fsSL "$BASE_URL/latest")}"

sed -i -E "s|(claude-code-releases/)[0-9]+\.[0-9]+\.[0-9]+(/linux-x64/claude)|\1$VERSION\2|" "$HERE/flake.nix"
sed -i -E "s|(version = \")[0-9]+\.[0-9]+\.[0-9]+(\";)|\1$VERSION\2|" package.nix
# Two locks: this feature's own, then the root's view of it.
nix flake update claude-code-bin --flake "$HERE"
nix flake update "feat-$(basename "$HERE")" --flake "$FLAKE_ROOT"
echo "pinned claude-code $VERSION -- rebuild to apply"
