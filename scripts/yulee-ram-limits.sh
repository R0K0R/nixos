#!/usr/bin/env bash
# Run on Yulee when remote builds OOM (KDE/Qt/Chromium-scale compiles).
# Lowers parallel Nix jobs and per-package compiler threads.
#
#   sudo ssh yulee 'bash -s' < ~/flakes/nixos/scripts/yulee-ram-limits.sh
#
# Tune with env vars, e.g. MAX_JOBS=6 CORES=1
set -euo pipefail

MAX_JOBS="${MAX_JOBS:-12}"
CORES="${CORES:-2}"
CONF="/etc/nix/nix.conf"

set_kv() {
  local key="$1" value="$2"
  if grep -q "^${key} " "${CONF}" 2>/dev/null; then
    sudo sed -i "s/^${key} .*/${key} = ${value}/" "${CONF}"
  else
    echo "${key} = ${value}" | sudo tee -a "${CONF}" >/dev/null
  fi
}

set_kv max-jobs "${MAX_JOBS}"
set_kv cores "${CORES}"

# Evict store paths sooner when disk/RAM pressure rises during huge builds.
set_kv min-free "2G"
set_kv max-free "8G"

sudo systemctl restart nix-daemon

echo "Yulee nix.conf now:"
grep -E '^(max-jobs|cores|min-free|max-free) ' "${CONF}" || true
echo
echo "On the laptop, match /etc/nix/machines job count (field 4) to ${MAX_JOBS}:"
echo "  sudo sed -i 's/ ssh_key [0-9]\\+/ ssh_key ${MAX_JOBS}/' /etc/nix/machines"
echo "  sudo systemctl restart nix-daemon"
