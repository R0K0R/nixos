#!/usr/bin/env bash
# Why is nixos-rebuild stuck on "waiting for the upload lock"?
set -euo pipefail

echo "=== Nix remote upload locks (one active uploader per store URL) ==="
sudo ls -lt /nix/var/nix/current-load/ 2>/dev/null | head -20 || true

echo
echo "=== Who holds upload locks? ==="
for lock in /nix/var/nix/current-load/*.upload-lock; do
  [[ -e "${lock}" ]] || continue
  echo "--- ${lock} ---"
  sudo fuser -v "${lock}" 2>/dev/null || echo "(no process)"
done

echo
echo "=== Nix daemons / rebuild ==="
pgrep -a nix-daemon || true
pgrep -a nixos-rebuild || true
pgrep -a 'nix (build|copy|store)' || true

echo
echo "=== Builder settings (root daemon) ==="
sudo nix show-config 2>/dev/null | rg '^(builders|builders-use-substitutes|max-jobs|substituters) ' || true

echo
echo "Tip: 315 MiB not moving + 'waiting for upload lock' = queued, not frozen."
echo "     ~250 KiB/s on Yulee ≈ one slow SSH nar copy; many GiB serially = hours."
