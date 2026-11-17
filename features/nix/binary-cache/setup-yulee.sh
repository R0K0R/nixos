#!/usr/bin/env bash
# harmonia on yulee as a systemd unit -- see yulee.md. Run as root, on yulee.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "run as root (sudo bash $0)" >&2; exit 1; }
KEY=/etc/nix/yulee-store-secret.key
[ -r "$KEY" ] || { echo "no signing key at $KEY" >&2; exit 1; }

# 1. harmonia, pinned in a system profile (a GC root)
nix --extra-experimental-features 'nix-command flakes' \
  build --profile /nix/var/nix/profiles/harmonia nixpkgs#harmonia
BIN=/nix/var/nix/profiles/harmonia/bin/harmonia-cache
[ -x "$BIN" ] || { echo "no $BIN" >&2; exit 1; }

# 2. config
install -d -m 0755 /etc/harmonia
cat > /etc/harmonia/config.toml <<'EOF'
bind = "[::]:5000"
priority = 30
EOF

# 3. unit: as the NixOS module runs it, DynamicUser + the key via LoadCredential
cat > /etc/systemd/system/harmonia.service <<EOF
[Unit]
Description=harmonia: this Nix store as an HTTP binary cache
After=network-online.target nix-daemon.service
Wants=network-online.target

[Service]
ExecStart=$BIN
Environment=CONFIG_FILE=/etc/harmonia/config.toml
Environment=SIGN_KEY_PATHS=%d/sign-key
LoadCredential=sign-key:$KEY
DynamicUser=yes
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable harmonia.service
systemctl restart harmonia.service
sleep 2
systemctl --no-pager --lines=5 status harmonia.service || true
curl -sf http://127.0.0.1:5000/nix-cache-info && echo "harmonia: OK"
