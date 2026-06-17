#!/usr/bin/env bash
# Install Flamenco Worker on yulee (Ubuntu). Fully non-interactive.
# Usage: sudo bash setup-flamenco-worker.sh <manager-url> <blender-binary> <gb4-host> [ssh-user]
# Example: sudo bash setup-flamenco-worker.sh http://galaxybook4-pro360:8080 /snap/bin/blender galaxybook4-pro360 r0k0r
set -euo pipefail

MANAGER_URL="${1:?Usage: $0 <manager-url> <blender-binary> <gb4-host> [ssh-user]}"
BLENDER_BIN="${2:?Usage: $0 <manager-url> <blender-binary> <gb4-host> [ssh-user]}"
GB4_HOST="${3:?Usage: $0 <manager-url> <blender-binary> <gb4-host> [ssh-user]}"
SSH_USER="${4:-r0k0r}"
FLAMENCO_VERSION="3.9.2"
FLAMENCO_URL="https://flamenco.blender.org/downloads/flamenco-${FLAMENCO_VERSION}-linux-amd64.tar.gz"
INSTALL_DIR="/opt/flamenco"
WORK_DIR="/var/lib/flamenco-worker"
SHARED_DIR="/var/lib/flamenco-manager/shared"
SSH_KEY="/root/.ssh/flamenco_mount_id"

[[ $EUID -ne 0 ]] && { echo "Run as root" >&2; exit 1; }
[[ -x "$BLENDER_BIN" ]] || { echo "Not executable: $BLENDER_BIN" >&2; exit 1; }

# ── Download & install binary ─────────────────────────────────────────────────
echo "Downloading Flamenco ${FLAMENCO_VERSION}..."
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
curl -fL "$FLAMENCO_URL" -o "$TMP/flamenco.tar.gz"
tar -xzf "$TMP/flamenco.tar.gz" -C "$TMP"
mkdir -p "$INSTALL_DIR"
install -m755 "$TMP/flamenco-${FLAMENCO_VERSION}-linux-amd64/flamenco-worker" "$INSTALL_DIR/flamenco-worker"

# ── System user & work dir ───────────────────────────────────────────────────
id flamenco &>/dev/null || useradd --system --home-dir "$WORK_DIR" --create-home --shell /usr/sbin/nologin flamenco
mkdir -p "$WORK_DIR"
chown flamenco:flamenco "$WORK_DIR"

# ── SSH key for SSHFS mount ───────────────────────────────────────────────────
if [[ ! -f "$SSH_KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -C "flamenco-mount@yulee" -f "$SSH_KEY"
fi

echo ""
echo "━━━ ADD THIS PUBLIC KEY TO ${SSH_USER}@${GB4_HOST}:~/.ssh/authorized_keys ━━━"
cat "${SSH_KEY}.pub"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  (or add to NixOS: users.users.${SSH_USER}.openssh.authorizedKeys.keys)"
echo ""

# ── SSHFS install & mount point ──────────────────────────────────────────────
apt-get install -y sshfs

FLAMENCO_UID=$(id -u flamenco)
FLAMENCO_GID=$(id -g flamenco)
mkdir -p "$SHARED_DIR"

# systemd unit name derived from mount path
MOUNT_UNIT=$(systemd-escape --path "$SHARED_DIR").mount

# ── systemd mount unit ────────────────────────────────────────────────────────
cat > "/etc/systemd/system/${MOUNT_UNIT}" << EOF
[Unit]
Description=Flamenco shared storage (SSHFS from ${GB4_HOST})
After=network-online.target
Wants=network-online.target

[Mount]
What=${SSH_USER}@${GB4_HOST}:${SHARED_DIR}
Where=${SHARED_DIR}
Type=fuse.sshfs
Options=_netdev,allow_other,IdentityFile=${SSH_KEY},uid=${FLAMENCO_UID},gid=${FLAMENCO_GID},reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,StrictHostKeyChecking=accept-new

[Install]
WantedBy=multi-user.target
EOF

# ── Worker config ─────────────────────────────────────────────────────────────
cat > "$WORK_DIR/flamenco-worker.yaml" << EOF
manager_url: "${MANAGER_URL}"
task_types:
  - blender
  - file-management
  - echo
  - sleep
EOF
chown flamenco:flamenco "$WORK_DIR/flamenco-worker.yaml"

# ── systemd worker unit ───────────────────────────────────────────────────────
cat > /etc/systemd/system/flamenco-worker.service << EOF
[Unit]
Description=Flamenco render farm worker
After=network.target ${MOUNT_UNIT}
Requires=${MOUNT_UNIT}

[Service]
ExecStart=${INSTALL_DIR}/flamenco-worker
WorkingDirectory=${WORK_DIR}
User=flamenco
Group=flamenco
Environment=BLENDER=${BLENDER_BIN}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${MOUNT_UNIT}"
echo ""
echo "Attempting SSHFS mount (will fail until you add the public key to ${GB4_HOST})..."
if systemctl start "${MOUNT_UNIT}" 2>/dev/null && mountpoint -q "$SHARED_DIR"; then
  echo "Mount OK."
  systemctl enable --now flamenco-worker
  echo "flamenco-worker running. Check: systemctl status flamenco-worker"
else
  echo ""
  echo "Mount not up yet — add the key to ${GB4_HOST} first, then run:"
  echo "  systemctl start '${MOUNT_UNIT}' && systemctl enable --now flamenco-worker"
fi
