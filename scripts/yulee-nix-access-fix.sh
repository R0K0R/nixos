#!/usr/bin/env bash
# Run on Yulee once (will prompt for sudo password):
#   bash scripts/yulee-nix-access-fix.sh
set -euo pipefail

sudo usermod -aG nix-users "$USER"

if ! grep -q '^experimental-features' /etc/nix/nix.conf 2>/dev/null; then
  echo 'experimental-features = nix-command flakes' | sudo tee -a /etc/nix/nix.conf
fi

if ! grep -q 'gccarch-meteorlake' /etc/nix/nix.conf || ! grep -q 'gccarch-znver3' /etc/nix/nix.conf; then
  echo 'Add gccarch-meteorlake and gccarch-znver3 to system-features in /etc/nix/nix.conf manually.' >&2
  exit 1
fi

sudo systemctl restart nix-daemon

echo "Done. Log out and back in (or: newgrp nix-users), then verify:"
echo "  nix --extra-experimental-features 'nix-command flakes' show-config | grep system-features"
echo "  nix-store --version"
