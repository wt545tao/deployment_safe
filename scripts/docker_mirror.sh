#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: docker_mirror.sh must run as root" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required to update /etc/docker/daemon.json" >&2
    exit 1
fi

MIRRORS="${DOCKER_REGISTRY_MIRRORS:-}"
if [ -z "$MIRRORS" ]; then
    echo "ERROR: DOCKER_REGISTRY_MIRRORS is empty" >&2
    exit 1
fi

DAEMON=/etc/docker/daemon.json
mkdir -p /etc/docker
if [ -s "$DAEMON" ]; then
    BACKUP="$DAEMON.bak.$(date +%Y%m%d%H%M%S)"
    cp "$DAEMON" "$BACKUP"
    echo "backed up existing daemon.json to $BACKUP"
fi

python3 - "$DAEMON" "$MIRRORS" <<'PY'
import json
import sys

path, raw = sys.argv[1], sys.argv[2]
mirrors = [m.strip() for m in raw.split(',') if m.strip()]

data = {}
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except FileNotFoundError:
    data = {}
except Exception as err:
    print("ERROR: cannot parse existing %s: %s" % (path, err), file=sys.stderr)
    sys.exit(2)

data['registry-mirrors'] = mirrors
with open(path, 'w', encoding='utf-8') as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write('\n')
print('registry-mirrors: ' + ', '.join(mirrors))
PY

if command -v systemctl >/dev/null 2>&1; then
    systemctl restart docker
else
    service docker restart
fi

echo "docker registry mirrors configured"
