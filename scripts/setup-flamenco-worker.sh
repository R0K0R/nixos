#!/usr/bin/env bash
# Install Flamenco Worker on yulee (Ubuntu).
# Run as root: sudo bash setup-flamenco-worker.sh
set -euo pipefail

FLAMENCO_VERSION="3.9.2"
FLAMENCO_URL="https://flamenco.blender.org/downloads/flamenco-${FLAMENCO_VERSION}-linux-amd64.tar.gz"
INSTALL_DIR="/opt/flamenco"
WORK_DIR="/var/lib/flamenco-worker"
BLENDER_BIN="${BLENDER_BIN:-$(command -v blender 2>/dev/null || echo '')}"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0" >&2
  exit 1
fi

# ── Blender check ────────────────────────────────────────────────────────────
if [[ -z "$BLENDER_BIN" ]]; then
  echo ""
  echo "Blender not found on PATH. Install it first, e.g.:"
  echo "  snap install blender --classic"
  echo "Then re-run with: BLENDER_BIN=/snap/bin/blender sudo -E bash $0"
  echo ""
  echo "Or pass BLENDER_BIN explicitly if installed to a custom path."
  exit 1
fi
echo "Using Blender: $BLENDER_BIN"

# ── Download & extract ───────────────────────────────────────────────────────
echo "Downloading Flamenco ${FLAMENCO_VERSION}..."
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
curl -fL "$FLAMENCO_URL" -o "$TMP/flamenco.tar.gz"
tar -xzf "$TMP/flamenco.tar.gz" -C "$TMP"

mkdir -p "$INSTALL_DIR"
install -m755 "$TMP/flamenco-${FLAMENCO_VERSION}-linux-amd64/flamenco-worker" "$INSTALL_DIR/flamenco-worker"
echo "Installed $INSTALL_DIR/flamenco-worker"

# ── System user ──────────────────────────────────────────────────────────────
if ! id flamenco &>/dev/null; then
  useradd --system --home-dir "$WORK_DIR" --create-home --shell /usr/sbin/nologin flamenco
  echo "Created system user 'flamenco'"
fi
mkdir -p "$WORK_DIR"
chown flamenco:flamenco "$WORK_DIR"

# ── systemd unit ─────────────────────────────────────────────────────────────
cat > /etc/systemd/system/flamenco-worker.service << EOF
[Unit]
Description=Flamenco render farm worker
After=network.target
# Only start after first-run wizard has written the config.
ConditionPathExists=${WORK_DIR}/flamenco-worker.yaml

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
echo "Installed flamenco-worker.service (not started yet)"

# ── First-run instructions ───────────────────────────────────────────────────
cat << 'EOF'

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Next steps:

1. On your laptop: run the Manager wizard once to create its config:
     sudo -u flamenco flamenco-manager
   Follow the prompts, then Ctrl-C and start the service:
     sudo systemctl enable --now flamenco-manager

2. Note the Manager URL (default: http://galaxybook4-pro360:8080 or the
   tailscale IP).

3. On yulee, run the Worker wizard:
     sudo -u flamenco /opt/flamenco/flamenco-worker \
       --manager-url http://<manager-host>:8080
   Follow the prompts. It writes /var/lib/flamenco-worker/flamenco-worker.yaml.

4. Enable the service:
     sudo systemctl enable --now flamenco-worker

5. Install the Blender addon from the Manager web UI (http://manager:8080)
   in Blender on the laptop: Edit → Preferences → Add-ons → Install from Disk.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
