#!/usr/bin/env bash
# One-time bootstrap so dell-latitude offloads builds to yulee as benjamin.
#
# Deliberately a SEPARATE keypair from the one galaxybook4-pro360 uses
# (age/remote-builder-ssh-key.age, user r0k0r). Two client hosts, two
# credentials, two authorized_keys entries on the peer -- revoking this laptop
# must not lock the other one out.
#
# UNLIKE victus-15, yulee has no hosts/yulee.nix in this flake -- it is not a
# nixosConfigurations output here, and its /etc/nix/nix.conf is hand-
# administered (see scripts/yulee-nix-access-fix.sh, which already documents
# that pattern for r0k0r). So this script cannot verify or grant benjamin
# trusted-user status on yulee, and it cannot create a benjamin account there
# either -- both are printed as manual steps, and the parts this script CAN
# verify (key auth, store access) are checked in a loop rather than assumed.
#
# Run on dell-latitude. Idempotent: an existing keypair is reused, never
# regenerated, because regenerating it would silently orphan the
# authorized_keys entry already installed on the peer.
set -euo pipefail

PEER_USER="benjamin"
PEER_HOST="yulee"
# The FQDN, spelled out: this bootstrap runs BEFORE the switch that installs
# the `Host yulee` alias into /etc/ssh/ssh_config, so nothing is translating
# the short name yet. yulee is a shared node from the `injoystickly@` tailnet
# and has no short MagicDNS name on this laptop.
PEER_ADDR="yulee.tail2d4da1.ts.net"
HOST="${1:-dell-latitude}"

KEY_SRC="${HOME}/.ssh/nix-remote-builder-${PEER_HOST}"
KEY_DST="/etc/nix/remote-builder/ssh_key"
MACHINES="/etc/nix/machines"
STORE_URL="ssh://${PEER_USER}@${PEER_ADDR}?ssh-key=${KEY_DST}"

if [[ ! -f "${KEY_SRC}" ]]; then
  echo "==> Generating ${KEY_SRC}"
  ssh-keygen -t ed25519 -N "" -C "nix-remote-builder@${PEER_USER}" -f "${KEY_SRC}"
else
  echo "==> Reusing existing ${KEY_SRC}"
fi

echo "==> Installing private key at ${KEY_DST}"
sudo install -D -m 600 -o "${USER}" -g users "${KEY_SRC}" "${KEY_DST}"

cat <<EOF

================================================================
STEP 1 -- on yulee itself (by hand -- it is not managed by this flake):

  a) Make sure a 'benjamin' account exists. If not, create one:
       sudo useradd -m -G nix-users benjamin
     (or whatever group grants Nix access there -- check
      scripts/yulee-nix-access-fix.sh, written for r0k0r on this same host.)

  b) Authorize this key for that account:

     Public key:

     $(cat "${KEY_SRC}.pub")

     Append it to benjamin's ~/.ssh/authorized_keys on yulee, or if you can
     already reach it some other way:

       ssh-copy-id -i ${KEY_SRC}.pub ${PEER_USER}@${PEER_ADDR}

  c) Add benjamin to trusted-users in /etc/nix/nix.conf on yulee:

       trusted-users = root @wheel r0k0r benjamin

     Not optional -- a remote build uploads the closure's missing paths
     before it builds anything, and an untrusted SSH user cannot do that.
     Skipping this fails at the upload with "cannot add path ... lacks a
     valid signature", NOT at authentication -- so the key looks fine and
     the failure reads like a cache problem.

     sudo systemctl restart nix-daemon    # on yulee, after editing
================================================================
EOF

until ssh -i "${KEY_SRC}" -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "${PEER_USER}@${PEER_ADDR}" true 2>/dev/null; do
  echo "!! Cannot yet SSH as ${PEER_USER}@${PEER_ADDR} with this key."
  echo "   Complete step 1a/1b on yulee first."
  read -rp "   Press enter to re-test, or ctrl-c to abort... " _
done
echo "==> SSH as ${PEER_USER}@${PEER_ADDR}: OK"

# Write /etc/nix/machines by hand for the bootstrap switch.
#
# THIS STEP IS NOT OPTIONAL and its absence is silent. `--builders
# '@/etc/nix/machines'` on a missing file is not an error -- it is an EMPTY
# builder list, so the switch fails with "local builds are disabled
# (max-jobs = 0)" and points at max-jobs, which is not the problem.
#
# The FQDN, not the `yulee` alias: the ssh_config block that defines that
# alias ships with the very switch this file exists to enable. The switch
# overwrites this file from nix.buildMachines, which is when the alias takes
# over.
echo "==> Writing ${MACHINES} for the bootstrap switch"
sudo install -d -m 755 /etc/nix
sudo tee "${MACHINES}" >/dev/null <<EOF
ssh://${PEER_USER}@${PEER_ADDR} x86_64-linux ${KEY_DST} 7 10 benchmark,big-parallel,kvm,nixos-test -
EOF

echo "==> Testing the remote store as ${PEER_USER}"
if ! sudo nix --extra-experimental-features 'nix-command' store info --store "${STORE_URL}"; then
  echo
  echo "!! Store access failed. This almost always means step 1c (trusted-users"
  echo "   on yulee, then restart nix-daemon there) is not done yet."
  exit 1
fi

cat <<EOF

================================================================
STEP 2 -- first switch on ${HOST}.

NixOS generates nix.conf with an empty builders=, so /etc/nix/machines is
ignored until a switch installs the new config. Run switch ONCE with the
builders passed explicitly (root is trusted, so the option is honoured):

  cd ~/flakes/nixos
  sudo nixos-rebuild switch --flake .#${HOST} \\
    --builders '@/etc/nix/machines' \\
    --option builders-use-substitutes true

Do NOT also pass --option max-jobs 0 to that command -- /etc/nix/machines
was just populated above, so builders alone is enough. Forcing max-jobs to 0
on the command line just means the switch has nowhere to fall back to if the
builders option is parsed differently than expected.

Afterwards plain \`sudo nixos-rebuild switch\` offloads on its own, and the
generated wrappers are available:

  nixos-rebuild-${PEER_HOST} switch   # this peer only
  nixos-rebuild-local switch          # local only -- but see the note below

NOTE: -local cannot fully escape the peer list. nixos-rebuild-ng does not pass
any flag to its \`nix eval\` step, and that step runs the doom-intermediates
IFD build, which the daemon dispatches via /etc/nix/machines. If ${PEER_HOST}
is down, park it instead:

  my.remote-builder.client.peers.${PEER_HOST}.enable = false;
================================================================
EOF
