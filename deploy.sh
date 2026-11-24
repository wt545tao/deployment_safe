#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: deploy.sh must run as root" >&2
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    PY="python3"
elif command -v python >/dev/null 2>&1; then
    PY="python"
else
    echo "ERROR: python3 not found" >&2
    exit 1
fi

if [ ! -f nginx/conf.d/app.conf ] || [ ! -f docker-compose.yml ]; then
    echo "ERROR: run deploy.sh from the repository root" >&2
    exit 1
fi

if [ -f .env ]; then
    set -a
    . ./.env
    set +a
fi

SETUP_FIREWALL="${SETUP_FIREWALL:-0}"
SETUP_FAIL2BAN="${SETUP_FAIL2BAN:-0}"
export SETUP_FIREWALL SETUP_FAIL2BAN

echo "[1/5] initialize server environment (docker required, firewall/fail2ban optional)"
bash scripts/init_server.sh

echo "[2/5] prepare environment file"
if [ ! -f .env ]; then
    SECRET="$(openssl rand -hex 32)"
    {
        echo "COMPOSE_PROJECT_NAME=safe"
        echo "SECRET_KEY=${SECRET}"
        echo "APP_IMAGE=${APP_IMAGE:-safe-app:local}"
        echo "DOMAIN=${DOMAIN:-localhost}"
        echo "SESSION_TTL=28800"
        echo "FAIL_WINDOW=600"
        echo "MAX_FAILS=3"
        echo "SETUP_FIREWALL=${SETUP_FIREWALL}"
        echo "SETUP_FAIL2BAN=${SETUP_FAIL2BAN}"
    } > .env
    chmod 600 .env
    echo "  generated .env with a fresh SECRET_KEY"
fi

set -a
. ./.env
set +a

mkdir -p data certs
touch data/auth.log

echo "[3/5] prepare TLS certificate"
if [ ! -s certs/fullchain.pem ] || [ ! -s certs/privkey.pem ]; then
    bash scripts/gen_cert.sh "${DOMAIN:-localhost}"
fi

echo "[4/5] manage bootstrap token"
TOKENS="$($PY auth-service/manage_tokens.py list 2>/dev/null || true)"
if [ -z "$TOKENS" ] || [ "$TOKENS" = "no tokens" ]; then
    $PY auth-service/manage_tokens.py add "${BOOTSTRAP_TOKEN_NAME:-bootstrap}"
else
    echo "$TOKENS"
fi

echo "[5/5] build and start containers"
if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "ERROR: docker compose is not available" >&2
    exit 1
fi

$DC up -d --build
$DC ps

ok=0
for _ in $(seq 1 30); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' safe-nginx 2>/dev/null || true)"
    if [ "$status" = "healthy" ]; then
        ok=1
        break
    fi
    sleep 2
done

if [ "$ok" -ne 1 ]; then
    echo "ERROR: safe-nginx did not become healthy, check: $DC logs nginx" >&2
    exit 1
fi

echo
echo "deployment finished"
echo "  login  : https://<server>/auth/login?token=<TOKEN>"
echo "  header : X-Auth-Token: <TOKEN>"
echo "  tokens : bash scripts/token_manager.sh add <name> | list | revoke <name>"
echo "  reset  : $PY auth-service/manage_tokens.py reset <ip>"
if [ "$SETUP_FIREWALL" != "1" ] || [ "$SETUP_FAIL2BAN" != "1" ]; then
    echo "  note   : firewall=${SETUP_FIREWALL} fail2ban=${SETUP_FAIL2BAN} (0=skipped, manage them on this server yourself)"
fi
