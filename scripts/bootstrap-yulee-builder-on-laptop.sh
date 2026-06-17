#!/usr/bin/env bash
# One-time bootstrap so the *next* nixos-rebuild switch uses Yulee via
# distributed builds (plain switch afterward — no --build-host).
set -euo pipefail

KEY_SRC="${HOME}/flakes/nixos/secrets/nix-remote-builder"
KEY_DST="/etc/nix/remote-builder/ssh_key"
MACHINES="/etc/nix/machines"
HOST="${1:-galaxybook4-pro360}"

if [[ ! -f "${KEY_SRC}" ]]; then
  echo "Missing ${KEY_SRC}" >&2
  exit 1
fi

sudo install -D -m 600 "${KEY_SRC}" "${KEY_DST}"

sudo tee "${MACHINES}" >/dev/null <<'EOF'
ssh://r0k0r@yulee x86_64-linux /etc/nix/remote-builder/ssh_key 4 2 benchmark,big-parallel,kvm,nixos-test,gccarch-meteorlake,gccarch-znver3 -
EOF

echo "OK. Test remote store:"
sudo nix --extra-experimental-features 'nix-command' store info \
  --store 'ssh://r0k0r@yulee?ssh-key=/etc/nix/remote-builder/ssh_key'

cat <<EOF

NixOS generates nix.conf with empty builders=, so /etc/nix/machines is ignored
until switch succeeds. Run switch ONCE with explicit builders (root is trusted):

  cd ~/flakes/nixos
  sudo nixos-rebuild switch --flake .#${HOST} \\
    --builders '@/etc/nix/machines' \\
    --option builders-use-substitutes true

After that, plain \`sudo nixos-rebuild switch\` is enough (or use scripts/nixos-rebuild-switch.sh).
EOF
