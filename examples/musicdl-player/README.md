# musicdl 音乐播放器部署样例

把 [musicdl](https://github.com/CharlesPikachu/musicdl) 的
`examples/claudeai-modern-web-music-player` 接入 `deployment_safe` 安全网关的完整样板：
应用在容器内监听 `8080`，对外只经 nginx 的 `80/443` 暴露，并复用统一的 token 鉴权与超频忽略策略。

```
examples/musicdl-player/
├── app.py             播放器 Flask 后端（来自 musicdl 官方样例）
├── serve.py           容器启动入口：绑定 0.0.0.0:8080，并补充 GET /healthz
├── static/            前端页面与静态资源
├── requirements.txt   flask / requests
├── Dockerfile         安装 musicdl + 以非 root 用户运行
├── deploy-oneclick.sh 一键脚本：国内源探测 + 写入 .env + 构建启动
└── .dockerignore
examples/compose.musicdl.override.yml   把 app 服务切到本样例
```

## 1. musicdl 安装方式

### 1.1 从 PyPI 安装（Dockerfile 默认）

```bash
pip install "musicdl>=2.12" flask requests
```

### 1.2 从本地源码安装

```bash
# 指向 musicdl 仓库根目录
pip install /path/to/musicdl
pip install flask requests
```

容器构建时也可以切换安装源：

```bash
docker build \
  --build-arg MUSICDL_SPEC="git+https://github.com/wt545tao/musicdl.git" \
  -t safe-musicdl-player:local examples/musicdl-player
```

> 从 git 安装时镜像内需要 `git`；如需可自行在 Dockerfile 中追加 `apt-get install -y git`。

## 2. 本地试运行（不走网关）

```bash
cd examples/musicdl-player
pip install -r requirements.txt "musicdl>=2.12"
PORT=8080 python serve.py
# 打开 http://127.0.0.1:8080
```

## 3. 通过 deployment_safe 部署

### 方式 0：一键脚本（国内 Docker 源自动探测，推荐）

```bash
sudo bash examples/musicdl-player/deploy-oneclick.sh
```

脚本依次完成：

1. 未安装 docker 时，用国内引擎源安装 docker-ce（`--engine-mirror tuna|aliyun|huawei`）；
2. 逐个探测候选 Hub 镜像前缀（先 `docker manifest inspect`，失败再 `docker pull`），
   自动选出能拉到 `python:3.11-slim` 与 `nginx:1.27-alpine` 的前缀；
3. 把结果写入 `.env`：`COMPOSE_FILE`、`APP_IMAGE`、`PYTHON_IMAGE`、`NGINX_IMAGE`、
   `MUSICDL_SPEC`、`PIP_INDEX_URL`、`PIP_TRUSTED_HOST`（已有值会被覆盖，其余键保留）；
4. 调用 `bash deploy.sh` 完成鉴权、证书、构建与启动，最后打印容器健康状态。

常用参数：

```bash
sudo bash examples/musicdl-player/deploy-oneclick.sh \
  --mirrors "https://<账号ID>.mirror.aliyuncs.com,docker.1ms.run" \
  --pip-index https://mirrors.aliyun.com/pypi/simple \
  --pip-host mirrors.aliyun.com \
  --musicdl-spec "musicdl>=2.14" \
  --with-mirror-config
```

> 候选镜像的可用性随时间变化，脚本以实际探测结果为准；全部失败时回退到 `docker.io` 并打印警告。
> `--with-mirror-config` 会额外改写 `/etc/docker/daemon.json` 并重启 docker（会重启已有容器）。
> musicdl 需要访问音乐平台，覆盖文件已给 `app` 追加 `egress` 网络；若不需要出网可自行移除。

### 方式 A：临时指定覆盖文件（只影响本次命令）

在项目根目录执行：

```bash
# 直接用 compose
COMPOSE_FILE=docker-compose.yml:examples/compose.musicdl.override.yml \
  docker compose up -d --build

# 或走 deploy.sh；注意 sudo 默认清空环境，变量要放在 sudo 后面
sudo COMPOSE_FILE=docker-compose.yml:examples/compose.musicdl.override.yml \
  bash deploy.sh
```

### 方式 B：写进 `.env`（长期生效）

`.env` 是项目根目录的环境变量文件：`deploy.sh` 会 `source` 它并 `export` 其中所有变量，
所以 `COMPOSE_FILE`、`APP_IMAGE` 写进去后，`deploy.sh` 里的 `docker compose up` 每次都会带上覆盖文件。

操作步骤：

1. 确认 `.env` 已存在（`deploy.sh` **只在 `.env` 不存在时生成**，已存在则不会覆盖）：

   ```bash
   ls -l .env || cp .env.example .env    # 若新建，记得把 SECRET_KEY 换成 openssl rand -hex 32
   chmod 600 .env
   ```

2. 追加两行：

   ```bash
   cat >> .env <<'EOF'
   APP_IMAGE=safe-musicdl-player:local
   COMPOSE_FILE=docker-compose.yml:examples/compose.musicdl.override.yml
   EOF
   ```

3. 正常部署：

   ```bash
   sudo bash deploy.sh
   ```

> 说明：`deploy.sh` 内部是 `set -a; . ./.env; set +a`，因此 `.env` 中新增的 `COMPOSE_FILE`
> 会被导出给后续的 `docker compose`。若绕过 `deploy.sh` 直接手敲 `docker compose up`，
> 请改用方式 A 的命令行前缀或 `docker compose -f docker-compose.yml -f examples/compose.musicdl.override.yml up -d --build`。

### 覆盖文件做了什么

覆盖文件做了四件事：
1. 把 `app` 服务的构建上下文指向 `examples/musicdl-player`；
2. 传入构建参数 `MUSICDL_SPEC`、`PIP_INDEX_URL`、`PIP_TRUSTED_HOST`，让 musicdl 从国内 PyPI 源安装；
3. 为下载目录挂载具名卷 `musicdl_downloads:/srv/downloads`，重建容器不丢文件；
4. 给 `app` 追加 `egress` 桥网络（保留 `internal`），使 musicdl 能访问音乐平台。

镜像默认名 `safe-musicdl-player:local`，可用 `.env` 的 `APP_IMAGE` 覆盖。

## 4. 与安全网关的对接点

| 项目 | 本样例实现 |
| --- | --- |
| 监听 | 容器内 `0.0.0.0:8080`（`serve.py`） |
| 健康检查 | `GET /healthz` 返回 `{"status":"ok"}`，供 compose 与 nginx 使用 |
| 端口 | 仅 `expose: 8080`，不出现在宿主机 |
| 网络 | `internal`（被 nginx 访问）+ `egress`（访问音乐平台），均不发布端口 |
| 用户 | `appuser`（uid 10001），非 root |
| 鉴权 | 应用不处理 token，统一由 nginx `auth_request` + auth 服务负责 |
| 下载卷 | 具名卷 `musicdl_downloads`，权限在镜像内已 chown 给 `appuser` |
| 流式 | `location /` 已设 `proxy_buffering off`，SSE 搜索/下载进度与 Range 播放可即时透传 |

## 5. 部署后验证

```bash
# 领取会话 Cookie（浏览器访问同理）
curl -k -c cookie.txt -L "https://<server>/auth/login?token=<TOKEN>"

# 来源列表接口
curl -k -H "X-Auth-Token: <TOKEN>" https://<server>/api/sources

# 健康检查（仅服务器本机）
curl -k https://127.0.0.1/healthz
```

无 token 访问会返回 `401`；同一 IP 在 `FAIL_WINDOW` 内无 token 访问超过 `MAX_FAILS` 次后，
连接会被静默关闭（无响应），窗口结束后自动恢复。

## 6. 注意事项

- **网络要求**：musicdl 需要能访问对应音乐平台的网络环境；覆盖文件已给 `app` 追加
  `egress` 桥网络，因此可以直接出网。若不希望出网，可从覆盖文件中删掉 `egress`，
  此时搜索/下载会失败（`internal` 网络本身禁止出网）。
- **国内源**：基础镜像由一键脚本探测国内 Hub 镜像前缀；musicdl 与依赖从
  `PIP_INDEX_URL` 指定的国内 PyPI 源安装。换源后无需改 Dockerfile，改 `.env` 或脚本参数即可。
- **访问频率**：搜索会逐条解析真实音频地址，`SEARCH_SIZE_PER_SOURCE` 越大越慢，按需调整。
- **会员音质**：需要在 `app.py` 的 `ClientManager._build()` 中按 musicdl 文档传入
  `default_search_cookies`。
- **版权**：仅供学习研究，请遵守各平台服务条款与版权规定。
- **生产建议**：样例使用 Flask 内置线程服务器；高并发场景可替换为 `waitress`/`gunicorn`。
