# Docker 国内源配置样例

Docker 相关有两个完全不同的“源”，先分清再配置：

| 类型 | 作用 | 本项目对应开关 |
| --- | --- | --- |
| Docker 引擎安装源（apt/yum 仓库） | 安装 `docker-ce` / `docker-compose-plugin` | `install-docker-ce.sh` |
| Docker Hub 镜像加速（registry mirror） | 拉取 `python:3.11-slim`、`nginx` 等镜像更快 | `SETUP_DOCKER_MIRROR` + `DOCKER_REGISTRY_MIRRORS` |

> 重要：**清华 TUNA 提供的是 Docker 引擎安装源，不提供 Docker Hub 镜像加速。**
> 阿里云、华为云的镜像加速地址需要登录各自控制台获取，不能写公共地址。

```
examples/docker-registry/
├── README.md
├── env.aliyun.example        追加到项目根 .env 的阿里云加速配置
├── env.huawei.example        追加到项目根 .env 的华为云加速配置
├── env.tuna.example          清华源说明（仅安装源，无 Hub 加速）
├── daemon.aliyun.json        阿里云 daemon.json 样例
├── daemon.huawei.json        华为云 daemon.json 样例
└── install-docker-ce.sh      按 MIRROR=tuna|aliyun|huawei 安装 Docker 引擎
```

## 1. 阿里云

### 1.1 获取专属加速地址

登录 [容器镜像服务控制台](https://cr.console.aliyun.com) → 镜像工具 → 镜像加速器，
复制形如 `https://<账号ID>.mirror.aliyuncs.com` 的地址。

### 1.2 写入项目 `.env`

```bash
cat examples/docker-registry/env.aliyun.example >> .env
# 编辑 .env，把 <你的账号ID> 替换成真实 ID
sudo bash deploy.sh
```

`deploy.sh` 会调用 `scripts/docker_mirror.sh` 写入 `/etc/docker/daemon.json` 并重启 docker。

### 1.3 直接使用 daemon.json

```bash
sudo cp examples/docker-registry/daemon.aliyun.json /etc/docker/daemon.json
# 先替换文件里的 <你的账号ID>
sudo systemctl restart docker
```

## 2. 华为云

### 2.1 获取加速地址

登录华为云 SWR 控制台，在“镜像加速”页面复制加速地址
（不同区域/实例地址不同，务必以控制台为准）。

### 2.2 写入项目 `.env`

```bash
cat examples/docker-registry/env.huawei.example >> .env
# 编辑 .env，填入控制台复制的地址
sudo bash deploy.sh
```

## 3. 清华 TUNA

清华源用于**安装 Docker 引擎**（`docker-ce` 的 apt/yum 仓库），不提供 Docker Hub 加速。

```bash
sudo MIRROR=tuna bash examples/docker-registry/install-docker-ce.sh
```

如果只需要拉镜像加速，请用阿里云/华为云的加速地址，或参考第 5 节的镜像前缀方式。

## 4. 安装 Docker 引擎（阿里/华为/清华）

```bash
sudo MIRROR=tuna   bash examples/docker-registry/install-docker-ce.sh
sudo MIRROR=aliyun bash examples/docker-registry/install-docker-ce.sh
sudo MIRROR=huawei bash examples/docker-registry/install-docker-ce.sh
```

脚本支持 Ubuntu/Debian（apt）与 CentOS/RHEL/Rocky/Alma/Fedora（yum），会：
1. 换用对应镜像站的 docker-ce 仓库；
2. 安装 `docker-ce docker-ce-cli containerd.io docker-compose-plugin`；
3. `systemctl enable --now docker`。

## 5. 方式二：直接替换镜像前缀

某些网络下 registry mirror 也不可用，可直接在 `.env` 里换镜像地址：

```bash
# 以 DaoCloud 公共代理为例（是否可用以你所在网络实测为准）
PYTHON_IMAGE=docker.m.daocloud.io/library/python:3.11-slim
NGINX_IMAGE=docker.m.daocloud.io/library/nginx:1.27-alpine
```

阿里云/华为云也提供带命名空间的镜像代理，但路径与权限各不相同，需按各自文档确认后替换。

## 6. 验证

```bash
docker info | grep -A5 "Registry Mirrors"
docker pull nginx:1.27-alpine
sudo bash deploy.sh
```

## 7. 注意事项

- 2024 年后国内公共 Docker Hub 加速大量关停，公共地址不稳定；优先用云厂商专属地址、自建 registry 或离线导入。
- 加速地址属于账号资源，不要提交到公开仓库；样例中一律使用 `<占位符>`。
- 修改 `daemon.json` 前先备份；`scripts/docker_mirror.sh` 已自动备份为 `daemon.json.bak.<时间戳>`。
- 企业内网请优先使用内部 registry，并遵守公司网络与合规要求。
