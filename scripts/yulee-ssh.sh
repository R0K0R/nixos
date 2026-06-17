#!/usr/bin/env bash
# SSH to Yulee over Tailscale (kernel tailscale0 — no ProxyCommand).
set -euo pipefail
exec ssh yulee "$@"
