#!/usr/bin/env bash
# Convenience wrapper: refreshes both cache tiers for one host in sequence
# (the same two-step done manually for galaxybook4-pro360). Tier 1 needs the
# live system closure, so run this ON the target host itself, after a
# nixos-rebuild switch/boot:
#   ./runtime-cache-refresh.sh [hostname]
# No argument = this machine's own hostname.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

HOST="${1:-$(hostname)}"

./refresh-tier1.sh "$HOST"
./refresh-tier2.sh "$HOST"

echo "done -- tier1 + tier2 refreshed for $HOST"
