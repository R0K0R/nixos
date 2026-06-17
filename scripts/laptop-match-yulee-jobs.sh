#!/usr/bin/env bash
# Match laptop /etc/nix/machines maxJobs to Yulee (default 8).
set -euo pipefail

MAX_JOBS="${1:-12}"
MACHINES="/etc/nix/machines"

sudo sed -i -E "s/(remote-builder/ssh_key) [0-9]+/\\1 ${MAX_JOBS}/" "${MACHINES}"

echo "Updated ${MACHINES}:"
cat "${MACHINES}"
sudo systemctl restart nix-daemon
