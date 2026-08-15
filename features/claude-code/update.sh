#!/usr/bin/env bash
# Bump the pinned claude-code: ./update.sh [version]
# No argument = whatever Anthropic's release channel calls "latest" right now.
# Rewrites the version in flake.nix (input URL) + package.nix, then relocks.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FLAKE_ROOT="$(git rev-parse --show-toplevel)"

BASE_URL="https://downloads.claude.ai/claude-code-releases"
VERSION="${1:-$(curl -fsSL "$BASE_URL/latest")}"

sed -i -E "s|(claude-code-releases/)[0-9]+\.[0-9]+\.[0-9]+(/linux-x64/claude)|\1$VERSION\2|" "$FLAKE_ROOT/flake.nix"
sed -i -E "s|(version = \")[0-9]+\.[0-9]+\.[0-9]+(\";)|\1$VERSION\2|" package.nix
nix flake update claude-code-bin --flake "$FLAKE_ROOT"
echo "pinned claude-code $VERSION -- rebuild to apply"
