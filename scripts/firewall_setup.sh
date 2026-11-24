#!/usr/bin/env bash
# Optional: deploy.sh only calls this script when SETUP_FIREWALL=1.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: firewall_setup.sh must run as root" >&2
    exit 1
fi

SSH_PORT="${SSH_PORT:-22}"

if ! command -v ufw >/dev/null 2>&1; then
    echo "WARN: ufw is not installed, skip firewall configuration" >&2
    exit 0
fi

ufw default deny incoming
ufw default allow outgoing
ufw allow "${SSH_PORT}/tcp"
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable
ufw status verbose
