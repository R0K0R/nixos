#!/usr/bin/env bash
# Sync laptop /etc/nix/machines and Yulee system-features with remote-builder-client.nix.
#
#   bash ~/flakes/nixos/scripts/restore-yulee-meteorlake-builder.sh
set -euo pipefail

MACHINES="/etc/nix/machines"
BUILDER_FEATURES="benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake,gccarch-znver3"

echo "=== Laptop: ${MACHINES} ==="
sudo tee "${MACHINES}" >/dev/null <<EOF
ssh://r0k0r@yulee x86_64-linux /etc/nix/remote-builder/ssh_key 8 4 ${BUILDER_FEATURES} -
EOF
cat "${MACHINES}"
sudo systemctl restart nix-daemon

echo ""
echo "=== Yulee: /etc/nix/nix.conf system-features ==="
sudo ssh yulee 'bash -s' <<'REMOTE'
set -euo pipefail
CONF=/etc/nix/nix.conf
if grep -q 'gccarch-meteorlake' "${CONF}" 2>/dev/null && grep -q 'gccarch-znver3' "${CONF}"; then
  echo "gccarch-meteorlake and gccarch-znver3 already present"
else
  if grep -q '^system-features ' "${CONF}"; then
    grep -q 'gccarch-meteorlake' "${CONF}" || sudo sed -i 's/^system-features = \(.*\)$/system-features = \1 gccarch-meteorlake/' "${CONF}"
    grep -q 'gccarch-znver3' "${CONF}" || sudo sed -i 's/^system-features = \(.*\)$/system-features = \1 gccarch-znver3/' "${CONF}"
  else
    echo 'system-features = benchmark big-parallel kvm nixos-test gccarch-meteorlake gccarch-znver3' | sudo tee -a "${CONF}" >/dev/null
  fi
fi
grep '^system-features ' "${CONF}" || true
sudo systemctl restart nix-daemon
REMOTE

echo ""
echo "OK. Rebuild (builds offload to Yulee via /etc/nix/machines):"
echo "  cd ~/flakes/nixos"
echo "  sudo nixos-rebuild switch --flake .#galaxybook4-pro360 \\"
echo "    --builders '@/etc/nix/machines' \\"
echo "    --option builders-use-substitutes true"
