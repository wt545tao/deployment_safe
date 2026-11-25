#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: init_server.sh must run as root" >&2
    exit 1
fi

if [ ! -r /etc/os-release ]; then
    echo "ERROR: unsupported operating system" >&2
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

SETUP_FIREWALL="${SETUP_FIREWALL:-0}"
SETUP_FAIL2BAN="${SETUP_FAIL2BAN:-0}"
SETUP_DOCKER_MIRROR="${SETUP_DOCKER_MIRROR:-0}"

if ! command -v curl >/dev/null 2>&1; then
    echo "ERROR: curl is required" >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "installing docker"
    curl -fsSL https://get.docker.com | sh
fi

systemctl enable --now docker >/dev/null 2>&1 || true

if ! docker compose version >/dev/null 2>&1 && ! command -v docker-compose >/dev/null 2>&1; then
    echo "ERROR: docker compose plugin is not available" >&2
    exit 1
fi

PKGS="openssl python3"
if [ "$SETUP_FIREWALL" = "1" ]; then
    PKGS="$PKGS ufw"
fi
if [ "$SETUP_FAIL2BAN" = "1" ]; then
    PKGS="$PKGS fail2ban iptables"
fi

echo "installing base packages: $PKGS"
case "${ID:-}" in
    ubuntu|debian)
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -y >/dev/null
        # shellcheck disable=SC2086
        apt-get install -y $PKGS >/dev/null
        ;;
    centos|rhel|rocky|almalinux|fedora|amzn)
        # shellcheck disable=SC2086
        yum install -y $PKGS >/dev/null 2>&1
        ;;
    *)
        echo "WARN: unknown distribution ${ID:-}, install manually: $PKGS" >&2
        ;;
esac

if [ "$SETUP_DOCKER_MIRROR" = "1" ]; then
    echo "configuring docker registry mirrors (SETUP_DOCKER_MIRROR=1)"
    DOCKER_REGISTRY_MIRRORS="${DOCKER_REGISTRY_MIRRORS:-https://docker.m.daocloud.io,https://dockerproxy.net}" \
        bash "$DEPLOY_DIR/scripts/docker_mirror.sh"
else
    echo "skipping docker registry mirror configuration (SETUP_DOCKER_MIRROR=0)"
fi

if [ "$SETUP_FIREWALL" = "1" ]; then
    echo "configuring ufw (SETUP_FIREWALL=1)"
    bash "$DEPLOY_DIR/scripts/firewall_setup.sh"
else
    echo "skipping firewall configuration (SETUP_FIREWALL=0)"
fi

if [ "$SETUP_FAIL2BAN" = "1" ]; then
    mkdir -p "$DEPLOY_DIR/data"
    touch "$DEPLOY_DIR/data/auth.log"
    if command -v fail2ban-client >/dev/null 2>&1; then
        echo "configuring fail2ban (SETUP_FAIL2BAN=1)"
        install -d /etc/fail2ban/filter.d /etc/fail2ban/jail.d
        install -m 0644 "$DEPLOY_DIR/fail2ban/filter.d/auth-gateway.conf" /etc/fail2ban/filter.d/auth-gateway.conf
        sed "s|__DEPLOY_DIR__|$DEPLOY_DIR|g" \
            "$DEPLOY_DIR/fail2ban/jail.d/auth-gateway.conf" > /etc/fail2ban/jail.d/auth-gateway.conf
        install -m 0644 "$DEPLOY_DIR/fail2ban/jail.d/sshd-hardening.conf" /etc/fail2ban/jail.d/sshd-hardening.conf
        systemctl enable fail2ban >/dev/null 2>&1 || true
        systemctl restart fail2ban >/dev/null 2>&1 || true
    else
        echo "WARN: fail2ban-client not found, skip fail2ban configuration" >&2
    fi
else
    echo "skipping fail2ban configuration (SETUP_FAIL2BAN=0)"
fi

echo "server environment is ready"
