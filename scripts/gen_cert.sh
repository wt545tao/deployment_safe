#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOMAIN="${1:-${DOMAIN:-localhost}}"

mkdir -p "$ROOT/certs"

if ! command -v openssl >/dev/null 2>&1; then
    echo "ERROR: openssl is not installed" >&2
    exit 1
fi

openssl req -x509 -newkey rsa:2048 -sha256 -days 825 -nodes \
    -keyout "$ROOT/certs/privkey.pem" \
    -out "$ROOT/certs/fullchain.pem" \
    -subj "/CN=${DOMAIN}" \
    -addext "subjectAltName=DNS:${DOMAIN},DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1

chmod 600 "$ROOT/certs/privkey.pem"
chmod 644 "$ROOT/certs/fullchain.pem"
echo "generated self-signed certificate for ${DOMAIN}"
