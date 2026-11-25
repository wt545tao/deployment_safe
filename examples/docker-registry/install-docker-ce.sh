#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: install-docker-ce.sh must run as root" >&2
    exit 1
fi

if [ ! -r /etc/os-release ]; then
    echo "ERROR: unsupported operating system" >&2
    exit 1
fi

# shellcheck disable=SC1091
. /etc/os-release

MIRROR="${MIRROR:-tuna}"
case "$MIRROR" in
    tuna)   BASE="https://mirrors.tuna.tsinghua.edu.cn/docker-ce" ;;
    aliyun) BASE="https://mirrors.aliyun.com/docker-ce" ;;
    huawei) BASE="https://mirrors.huaweicloud.com/docker-ce" ;;
    *)
        echo "ERROR: MIRROR must be one of: tuna, aliyun, huawei" >&2
        exit 1
        ;;
esac

echo "using docker-ce mirror: $MIRROR ($BASE)"

case "${ID:-}" in
    ubuntu|debian)
        apt-get update -y
        apt-get install -y ca-certificates curl gnupg
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL "$BASE/linux/${ID}/gpg" | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        chmod a+r /etc/apt/keyrings/docker.gpg
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] $BASE/linux/${ID} ${VERSION_CODENAME} stable" \
            > /etc/apt/sources.list.d/docker.list
        apt-get update -y
        apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        ;;
    centos|rhel|rocky|almalinux|fedora)
        case "${ID}" in
            fedora) REPO_DIST="fedora" ;;
            *)      REPO_DIST="centos" ;;
        esac
        curl -fsSL "$BASE/linux/$REPO_DIST/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo
        sed -i "s|https://download.docker.com|$BASE|g" /etc/yum.repos.d/docker-ce.repo
        if command -v dnf >/dev/null 2>&1; then
            dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        else
            yum install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
        fi
        ;;
    *)
        echo "ERROR: unsupported distribution ${ID:-}, install docker-ce manually with mirror: $BASE" >&2
        exit 1
        ;;
esac

systemctl enable --now docker
docker version
echo "docker engine installed from $MIRROR mirror"
