#!/usr/bin/env bash
# Bump the pinned claude-science: ./update.sh [version]
# No argument = whatever /latest/ currently redirects to.
# Rewrites the version in THIS feature's flake.nix (input URL *and* the
# exported version), then relocks both the feature and the root's view of it.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FLAKE_ROOT="$(git rev-parse --show-toplevel)"
HERE="$(pwd)"   # this feature's own directory; its flake.nix owns the pin

BASE_URL="https://downloads.claude.ai/claude-science"

# There is no version index to read, only a /latest/ alias. The binary names
# itself, so ask it: the download is content-dispositioned
# claude-science-<version>-linux-x64.
if [[ $# -ge 1 ]]; then
  VERSION="$1"
else
  VERSION="$(curl -fsSLI "$BASE_URL/latest/linux-x64" \
    | grep -oiE 'claude-science-[0-9]+(\.[0-9]+)*-linux-x64' \
    | grep -oE '[0-9]+(\.[0-9]+)+' | tail -n 1)"
  [[ -n "$VERSION" ]] || {
    echo "could not read the version from /latest/; pass it explicitly" >&2
    exit 1
  }
fi

sed -i -E "s|(claude-science/)[0-9]+(\.[0-9]+)*(/linux-x64)|\1$VERSION\3|" "$HERE/flake.nix"
sed -i -E "s|(version = \")[0-9]+(\.[0-9]+)*(\";)|\1$VERSION\3|" "$HERE/flake.nix"
# Two locks: this feature's own, then the root's view of it.
nix flake update claude-science-bin --flake "$HERE"
nix flake update "feat-$(basename "$HERE")" --flake "$FLAKE_ROOT"
echo "pinned claude-science $VERSION -- rebuild to apply"
