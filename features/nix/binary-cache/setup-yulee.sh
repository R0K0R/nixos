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

# 4. yulee as a client: victus-15's cache and key, and the short stall timeout
#    galaxybook and victus-15 get from my.nix-settings. A marked block, replaced
#    on every run; extra-* so yulee's own substituters and keys stay as they are.
CONF=/etc/nix/nix.conf
BEGIN='# BEGIN binary-cache (etc/nixos features/nix/binary-cache/setup-yulee.sh)'
END='# END binary-cache'
cp -a "$CONF" "$CONF.bak-$(date +%Y%m%d-%H%M%S)"
sed -i "\|^$BEGIN\$|,\|^$END\$|d" "$CONF"
cat >> "$CONF" <<EOF
$BEGIN
extra-substituters = http://victus-15:5000?priority=10
extra-trusted-public-keys = victus-15-1:W5OP8VVbu7Q7z2o5grHJ5Zp+ynm536+QVv+b8fBQJlQ=
stalled-download-timeout = 15
$END
EOF
# The daemon reads nix.conf at start. A restart kills builds it is running.
# Each client connection is its own nix-daemon process; more than the one
# listener means someone is connected (a build, a copy, a peer's builder).
if [ "$(pgrep -c -x nix-daemon)" -gt 1 ]; then
  echo "nix-daemon has active workers; restart it yourself when idle: systemctl restart nix-daemon" >&2
else
  systemctl restart nix-daemon
  echo "nix-daemon restarted"
fi
nix config show substituters
nix config show stalled-download-timeout
