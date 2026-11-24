#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if command -v python3 >/dev/null 2>&1; then
    PY="python3"
elif command -v python >/dev/null 2>&1; then
    PY="python"
else
    echo "ERROR: python3 not found" >&2
    exit 1
fi

FAILED=0

echo "== shell syntax =="
for script in deploy.sh scripts/*.sh tests/*.sh; do
    if bash -n "$script"; then
        echo "OK   $script"
    else
        echo "FAIL $script"
        FAILED=1
    fi
done

echo "== python compile =="
if $PY -m py_compile auth-service/app.py auth-service/verify.py auth-service/manage_tokens.py app/app.py examples/sample-app/app.py; then
    echo "OK   python sources compile"
else
    echo "FAIL python sources"
    FAILED=1
fi

echo "== auth service unit tests =="
if $PY tests/test_auth.py; then
    echo "OK   auth unit tests"
else
    echo "FAIL auth unit tests"
    FAILED=1
fi

echo "== auth service http integration tests =="
if $PY tests/test_app.py; then
    echo "OK   auth http integration tests"
else
    echo "FAIL auth http integration tests"
    FAILED=1
fi

echo "== docker-compose yaml =="
if $PY -c "import yaml" >/dev/null 2>&1; then
    if $PY -c "import yaml; yaml.safe_load(open('docker-compose.yml', encoding='utf-8'))"; then
        echo "OK   docker-compose.yml is valid yaml"
    else
        echo "FAIL docker-compose.yml"
        FAILED=1
    fi
else
    echo "SKIP pyyaml not installed"
fi

echo "== fail2ban filter =="
if $PY -c "import configparser; c=configparser.ConfigParser(); c.read('fail2ban/filter.d/auth-gateway.conf'); assert 'Definition' in c.sections()"; then
    echo "OK   fail2ban filter format"
else
    echo "FAIL fail2ban filter format"
    FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
    echo "validation FAILED"
    exit 1
fi

echo "validation PASSED"
