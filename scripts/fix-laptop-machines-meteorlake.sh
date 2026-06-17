#!/usr/bin/env bash
# Nix reads builder features from /etc/nix/machines on the laptop — not from Yulee live.
# If you see "Failed to find a machine" for gccarch-meteorlake, run this on Galaxy Book:
#
#   bash ~/flakes/nixos/scripts/fix-laptop-machines-meteorlake.sh
set -euo pipefail

MACHINES="/etc/nix/machines"
FEATURES="benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake,gccarch-znver3"

sudo tee "${MACHINES}" >/dev/null <<EOF
ssh://r0k0r@yulee x86_64-linux /etc/nix/remote-builder/ssh_key 8 4 ${FEATURES} -
EOF

echo "Wrote ${MACHINES}:"
cat "${MACHINES}"
sudo systemctl restart nix-daemon
echo "Restarted nix-daemon. Yulee needs gccarch-meteorlake + gccarch-znver3 (see qt6-remote-bootstrap.nix)."
echo "  sudo ssh yulee 'grep ^system-features /etc/nix/nix.conf'"
