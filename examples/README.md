# 示例应用部署样板

本目录给出一个可直接运行、也可直接复制改造的示例应用，以及把它接入 `deployment_safe` 安全网关的样板配置。

```
examples/
├── sample-app/                   示例应用（标准库，无第三方依赖）
│   ├── app.py
│   └── Dockerfile
├── musicdl-player/               musicdl 音乐播放器部署样例
│   ├── app.py                    播放器 Flask 后端（musicdl 官方样例）
│   ├── serve.py                  容器入口：0.0.0.0:8080 + /healthz
│   ├── static/                   前端资源
│   ├── requirements.txt
│   ├── Dockerfile
│   └── README.md                 安装与部署说明
├── docker-registry/              Docker 国内源配置样例（阿里/华为/清华）
│   ├── README.md
│   ├── env.aliyun.example
│   ├── env.huawei.example
│   ├── env.tuna.example
│   ├── daemon.aliyun.json
│   ├── daemon.huawei.json
│   └── install-docker-ce.sh
├── compose.override.yml          用示例应用替换默认 demo 的 compose 覆盖文件
├── compose.musicdl.override.yml  用 musicdl 播放器替换默认 demo 的覆盖文件
└── README.md
```

## 1. 接入约定（必须满足）

| 项目 | 要求 |
| --- | --- |
| 监听端口 | 容器内 `8080`（如不同，需同步修改 `nginx/conf.d/app.conf` 的 upstream） |
| 健康检查 | 提供 `GET /healthz`，正常返回 2xx |
| 端口暴露 | 只用 `expose: 8080`，**不要**使用 `ports:` |
| 网络 | 只加入 `internal` 网络，**不要**加入 `edge` |
| 权限 | 容器内以非 root 用户运行（样板 Dockerfile 已示范） |
| 鉴权 | 不要在应用里实现 token 校验，统一交给 nginx + auth 服务 |

## 2. 方式一：用样板应用替换默认 demo

在项目根目录执行：

```bash
COMPOSE_FILE=docker-compose.yml:examples/compose.override.yml \
  docker compose up -d --build
```

`compose.override.yml` 只做一件事：把 `app` 服务的构建上下文指向 `examples/sample-app`。

## 3. 方式二：使用已有业务镜像

编辑项目根目录 `.env`：

```bash
APP_IMAGE=registry.example.com/team/my-app:1.0.0
```

并修改 `docker-compose.yml` 中 `app` 服务，去掉 `build`（或保留但不再构建）：

```yaml
services:
  app:
    image: ${APP_IMAGE}
    container_name: safe-app
    restart: unless-stopped
    expose:
      - "8080"
    networks:
      - internal
    security_opt:
      - no-new-privileges:true
    healthcheck:
      test: ["CMD", "python", "-c", "import urllib.request;urllib.request.urlopen('http://127.0.0.1:8080/healthz',timeout=3)"]
      interval: 30s
      timeout: 5s
      retries: 3
```

镜像内必须自带健康检查所需的命令（示例用 python）。若镜像没有 python/curl/wget，可改用镜像内已有的工具，或临时去掉 `healthcheck`。

然后重新部署：

```bash
sudo bash deploy.sh
```

## 4. 方式三：复制样板到自己的目录

```bash
cp -r examples/sample-app my-app
# 修改 my-app/app.py 与 Dockerfile
```

再把 `docker-compose.yml` 的 `app.build` 改为 `./my-app` 即可。

## 5. 部署后验证

```bash
# 领取会话 Cookie 并跳转首页
curl -k -c cookie.txt -L "https://<server>/auth/login?token=<TOKEN>"

# 直接访问业务接口
curl -k -H "X-Auth-Token: <TOKEN>" https://<server>/api/info

# 健康检查（仅服务器本机可访问）
curl -k https://127.0.0.1/healthz
```

## 6. 示例二：musicdl 音乐播放器

`examples/musicdl-player/` 演示如何把真实第三方应用（musicdl 的
`claudeai-modern-web-music-player`）接入本网关，含 musicdl 安装、镜像构建、
非 root 运行、`/healthz` 健康检查与下载目录持久化。

```bash
COMPOSE_FILE=docker-compose.yml:examples/compose.musicdl.override.yml \
  docker compose up -d --build
```

安装方式、配置项与注意事项详见 [`musicdl-player/README.md`](musicdl-player/README.md)。

## 7. Docker 国内源配置

`examples/docker-registry/` 提供阿里云、华为云、清华源的配置样例：

- 阿里云 / 华为云：`registry-mirrors` 镜像加速（需控制台获取专属地址）；
- 清华 TUNA：Docker 引擎安装源（`docker-ce` 的 apt/yum 仓库），不提供 Docker Hub 加速；
- `install-docker-ce.sh`：`sudo MIRROR=tuna|aliyun|huawei` 一键换源安装 Docker。

详见 [`docker-registry/README.md`](docker-registry/README.md)。

## 8. 常见问题

- **502 Bad Gateway**：app 容器未 healthy，或没有监听 8080；查看 `docker compose logs -f app`。
- **一直 401**：请求未携带 token/Cookie；用 `/auth/login?token=...` 或 `X-Auth-Token` 头。
- **连接被重置（无响应）**：同一 IP 在 `FAIL_WINDOW` 内无 token 访问超过 `MAX_FAILS` 次，被限流忽略；等待窗口结束或执行 `bash scripts/token_manager.sh reset <ip>`。
- **证书告警**：默认是自签证书，公网请替换 `certs/` 下的证书。
