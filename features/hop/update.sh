#!/usr/bin/env bash
# Bump the pinned HOP: ./update.sh [version]
# No argument = newest non-prerelease tag on golbin/hop.
#
# Only flake.nix is rewritten -- both the input URL and the exported `version`
# live there, and package.nix takes the version as an argument. That is the one
# deliberate difference from ../claude-desktop/update.sh, which has to sed two
# files because its package.nix repeats the literal.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
FLAKE_ROOT="$(git rev-parse --show-toplevel)"
HERE="$(pwd)"   # this feature's own directory; its flake.nix owns the pin

if [[ $# -ge 1 ]]; then
  VERSION="${1#v}"
else
  # /releases/latest already excludes prereleases and drafts.
  VERSION="$(curl -fsSL https://api.github.com/repos/golbin/hop/releases/latest \
    | grep -m1 '"tag_name"' | cut -d'"' -f4)"
  VERSION="${VERSION#v}"
fi

# The tag appears twice in the URL (path + filename is one occurrence each in
# practice: .../download/v<ver>/HOP-linux-x64.deb), plus the version attr.
sed -i -E "s|(/download/v)[0-9]+(\.[0-9]+)*(/)|\1$VERSION\3|" flake.nix
sed -i -E "s|(version = \")[0-9]+(\.[0-9]+)*(\";)|\1$VERSION\3|" flake.nix

# Two locks: this feature's own, then the root's view of it. Without the second
# the root keeps serving the old narHash and nothing appears to change.
nix flake update hop-bin --flake "$HERE"
nix flake update "feat-$(basename "$HERE")" --flake "$FLAKE_ROOT"

echo "pinned HOP $VERSION -- rebuild to apply"
echo "NOTE: verify the .desktop Exec line and MimeType are unchanged upstream;"
echo "      package.nix uses --replace-fail so a rename fails the build loudly."
