#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT"

DEFAULT_MIRRORS="docker.1ms.run,docker.1panel.live,hub.rat.dev,docker.m.daocloud.io,dockerproxy.net,docker.xuanyuan.me,docker.hlmirror.com"

MIRRORS="${DOCKER_HUB_MIRRORS:-$DEFAULT_MIRRORS}"
PIP_INDEX_URL="${PIP_INDEX_URL:-https://pypi.tuna.tsinghua.edu.cn/simple}"
PIP_TRUSTED_HOST="${PIP_TRUSTED_HOST:-pypi.tuna.tsinghua.edu.cn}"
MUSICDL_SPEC="${MUSICDL_SPEC:-musicdl>=2.12}"
DOCKER_ENGINE_MIRROR="${DOCKER_ENGINE_MIRROR:-tuna}"
WITH_MIRROR_CONFIG=0
PROBE=1

usage() {
    cat <<'EOF'
Usage: sudo bash examples/musicdl-player/deploy-oneclick.sh [options]

Install musicdl and deploy claudeai-modern-web-music-player behind the safe
gateway, pulling base images through domestic Docker Hub mirrors.

Options:
  --mirrors a,b,c       Docker Hub mirror prefixes, comma separated
  --pip-index URL       pip index used to install musicdl (default: tsinghua)
  --pip-host HOST       pip trusted host (default: pypi.tuna.tsinghua.edu.cn)
  --musicdl-spec SPEC   pip requirement (default: musicdl>=2.12)
  --engine-mirror NAME  docker-ce repo mirror: tuna|aliyun|huawei (default: tuna)
  --with-mirror-config  also write registry-mirrors into /etc/docker/daemon.json
  --no-probe            skip probing, use the first mirror prefix as is
  -h, --help            show this help

The same names as environment variables are supported, e.g.
  sudo DOCKER_HUB_MIRRORS="https://<id>.mirror.aliyuncs.com" bash examples/musicdl-player/deploy-oneclick.sh
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --mirrors) MIRRORS="$2"; shift 2 ;;
        --pip-index) PIP_INDEX_URL="$2"; shift 2 ;;
        --pip-host) PIP_TRUSTED_HOST="$2"; shift 2 ;;
        --musicdl-spec) MUSICDL_SPEC="$2"; shift 2 ;;
        --engine-mirror) DOCKER_ENGINE_MIRROR="$2"; shift 2 ;;
        --with-mirror-config) WITH_MIRROR_CONFIG=1; shift ;;
        --no-probe) PROBE=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ -z "$MIRRORS" ]; then
    echo "ERROR: --mirrors must not be empty" >&2
    exit 1
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run this script as root (sudo)" >&2
    exit 1
fi

if command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
else
    echo "ERROR: python3 is required" >&2
    exit 1
fi

run_timeout() {
    local seconds="$1"
    shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

if ! command -v docker >/dev/null 2>&1; then
    echo "[1/6] docker not found, installing docker-ce from mirror: $DOCKER_ENGINE_MIRROR"
    MIRROR="$DOCKER_ENGINE_MIRROR" bash examples/docker-registry/install-docker-ce.sh
else
    echo "[1/6] docker already installed: $(docker --version)"
fi

systemctl enable --now docker >/dev/null 2>&1 || true
for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && break
    sleep 2
done
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: docker daemon is not ready" >&2
    exit 1
fi

if docker compose version >/dev/null 2>&1; then
    DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    DC="docker-compose"
else
    echo "ERROR: docker compose is not available" >&2
    exit 1
fi

normalize_prefix() {
    local prefix="$1"
    prefix="${prefix#http://}"
    prefix="${prefix#https://}"
    prefix="${prefix%/}"
    printf '%s' "$prefix"
}

find_image() {
    local image="$1" prefix candidate
    if [ "$PROBE" != "1" ]; then
        prefix="$(normalize_prefix "${MIRRORS%%,*}")"
        printf '%s/library/%s\n' "$prefix" "$image"
        return 0
    fi
    for prefix in ${MIRRORS//,/ }; do
        candidate="$(normalize_prefix "$prefix")/library/$image"
        if run_timeout 60 docker manifest inspect "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    for prefix in ${MIRRORS//,/ }; do
        candidate="$(normalize_prefix "$prefix")/library/$image"
        echo "  pulling $candidate" >&2
        if run_timeout 600 docker pull "$candidate" >/dev/null 2>&1; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

echo "[2/6] probing docker hub mirrors"
echo "  candidates: $MIRRORS"
if PYTHON_IMAGE_RESOLVED="$(find_image python:3.11-slim)"; then
    echo "  python base image: $PYTHON_IMAGE_RESOLVED"
else
    PYTHON_IMAGE_RESOLVED="python:3.11-slim"
    echo "  WARN: no mirror served python:3.11-slim, falling back to docker.io" >&2
fi
if NGINX_IMAGE_RESOLVED="$(find_image nginx:1.27-alpine)"; then
    echo "  nginx base image : $NGINX_IMAGE_RESOLVED"
else
    NGINX_IMAGE_RESOLVED="nginx:1.27-alpine"
    echo "  WARN: no mirror served nginx:1.27-alpine, falling back to docker.io" >&2
fi

if [ "$WITH_MIRROR_CONFIG" = "1" ]; then
    echo "[3/6] writing registry mirrors into /etc/docker/daemon.json"
    MIRROR_URLS=""
    while IFS= read -r mirror; do
        [ -z "$mirror" ] && continue
        case "$mirror" in
            http*) url="$mirror" ;;
            *) url="https://$mirror" ;;
        esac
        MIRROR_URLS="${MIRROR_URLS:+$MIRROR_URLS,}$url"
    done <<< "$(printf '%s' "$MIRRORS" | tr ',' '\n')"
    DOCKER_REGISTRY_MIRRORS="$MIRROR_URLS" bash scripts/docker_mirror.sh
else
    echo "[3/6] skip daemon.json rewrite (use --with-mirror-config to enable)"
fi

echo "[4/6] writing .env for the safe gateway"
"$PY" - "$ROOT/.env" "$PYTHON_IMAGE_RESOLVED" "$NGINX_IMAGE_RESOLVED" "$MUSICDL_SPEC" "$PIP_INDEX_URL" "$PIP_TRUSTED_HOST" <<'PY'
import os
import re
import sys

path, py_image, nginx_image, spec, pip_index, pip_host = sys.argv[1:7]


def quote(value):
    escaped = (value.replace('\\', '\\\\')
                    .replace('"', '\\"')
                    .replace('$', '\\$')
                    .replace('`', '\\`'))
    return '"%s"' % escaped


overwrite = {
    'COMPOSE_FILE': 'docker-compose.yml:examples/compose.musicdl.override.yml',
    'APP_IMAGE': 'safe-musicdl-player:local',
    'PYTHON_IMAGE': py_image,
    'NGINX_IMAGE': nginx_image,
    'MUSICDL_SPEC': spec,
    'PIP_INDEX_URL': pip_index,
    'PIP_TRUSTED_HOST': pip_host,
}
defaults = {
    'COMPOSE_PROJECT_NAME': 'safe',
    'SECRET_KEY': os.urandom(32).hex(),
    'DOMAIN': 'localhost',
    'SESSION_TTL': '28800',
    'FAIL_WINDOW': '600',
    'MAX_FAILS': '3',
    'SETUP_FIREWALL': '0',
    'SETUP_FAIL2BAN': '0',
}

lines = []
if os.path.exists(path):
    with open(path, 'r', encoding='utf-8') as handle:
        lines = handle.read().splitlines()

present = set()
result = []
for line in lines:
    match = re.match(r'^([A-Za-z_][A-Za-z0-9_]*)=', line)
    if match and match.group(1) in overwrite:
        key = match.group(1)
        result.append('%s=%s' % (key, quote(overwrite[key])))
        present.add(key)
        continue
    if match:
        present.add(match.group(1))
    result.append(line)

for key, value in list(defaults.items()) + list(overwrite.items()):
    if key in present:
        continue
    result.append('%s=%s' % (key, quote(value)))
    present.add(key)

with open(path, 'w', encoding='utf-8') as handle:
    handle.write('\n'.join(result) + '\n')
os.chmod(path, 0o600)
print('  updated %s' % path)
print('  PYTHON_IMAGE=%s' % py_image)
print('  NGINX_IMAGE=%s' % nginx_image)
print('  MUSICDL_SPEC=%s' % spec)
print('  PIP_INDEX_URL=%s' % pip_index)
PY

set -a
# shellcheck disable=SC1091
. ./.env
set +a

echo "[5/6] building and starting the gateway plus musicdl player"
bash deploy.sh

echo "[6/6] verifying containers"
$DC ps
app_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' safe-app 2>/dev/null || echo missing)"
nginx_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' safe-nginx 2>/dev/null || echo missing)"
echo "  safe-app   health: $app_status"
echo "  safe-nginx health: $nginx_status"
if [ "$app_status" != "healthy" ] || [ "$nginx_status" != "healthy" ]; then
    echo "WARN: containers are not healthy yet, inspect with: $DC logs app nginx" >&2
fi

echo
echo "deployment finished"
echo "  login  : https://<server>/auth/login?token=<TOKEN>"
echo "  header : X-Auth-Token: <TOKEN>"
echo "  tokens : bash scripts/token_manager.sh list"
echo "  musicdl: installed inside the app image via $PIP_INDEX_URL"
echo "  images : $PYTHON_IMAGE_RESOLVED / $NGINX_IMAGE_RESOLVED"
