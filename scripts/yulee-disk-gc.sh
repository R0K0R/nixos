#!/usr/bin/env bash
# Free space on Yulee when remote builds fail with "No space left on device".
#
# Run from laptop:
#   bash ~/flakes/nixos/scripts/yulee-ssh.sh 'bash -s' < ~/flakes/nixos/scripts/yulee-disk-gc.sh
# Or on Yulee:
#   sudo bash ~/flakes/nixos/scripts/yulee-disk-gc.sh
set -euo pipefail

echo "=== Before ==="
df -h / /nix /home 2>/dev/null || df -h /
du -sh /nix/store /home /var/log 2>/dev/null || true
du -h --max-depth=1 /home 2>/dev/null | sort -hr | head -10 || true

echo
echo "=== nix-store GC ==="
sudo nix-store --gc --print-dead 2>/dev/null | wc -l || true
sudo nix-collect-garbage -d

echo
echo "=== After ==="
df -h / /nix /home 2>/dev/null || df -h /
du -sh /nix/store /home 2>/dev/null || true

echo
echo "If /home is still full, inspect large dirs under /home and remove old caches manually."
