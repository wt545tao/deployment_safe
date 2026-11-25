# deployment_safe

一套"默认拒绝 + Token 授权 + 超频忽略"的安全部署方案：业务应用容器化运行，只通过 80/443 对外提供服务，未授权访问默认不响应。

## 1. 架构

```
Internet
   |  80 / 443 (仅这两个端口)
   v
+-------------------+
|  safe-nginx       |   TLS 终结、限流、安全响应头、auth_request 鉴权
|  edge + internal  |
+---------+---------+
          | internal 网络（internal: true，无法访问外网）
   +------+------+
   |             |
   v             v
safe-auth      safe-app
(鉴权服务)      (业务应用 8080，仅内网 expose)
```

- 业务容器与鉴权容器**不发布任何端口**，只能被 nginx 通过 internal 网络访问。
- 鉴权服务只存 token 的 SHA-256 哈希；校验通过后签发 HMAC-SHA256 签名、绑定客户端 IP 的会话 Cookie。
- 无 token / 错误 token 的访问在窗口内超过阈值后，nginx 直接 `return 444` 关闭连接，不返回任何响应。
- ufw 与 fail2ban 属于**可选项**，默认不配置，由部署服务器自行管理；本项目仅在显式开启时安装/写入规则。

## 2. 目录结构

```
deploy.sh                    一键部署入口（需 root）
docker-compose.yml           app / auth / nginx 三服务编排
.env.example                 环境变量样例
nginx/nginx.conf             全局配置（限流 zone、日志格式）
nginx/conf.d/app.conf        443 网关、auth_request、限流、安全头、444 忽略
auth-service/verify.py       Token / 会话 / 超频计数核心逻辑（仅标准库）
auth-service/app.py          鉴权 HTTP 服务（仅标准库）
auth-service/manage_tokens.py Token 与失败计数管理 CLI
app/                         默认示例业务应用
examples/                    示例应用部署样板（推荐从这里复制）
fail2ban/                    fail2ban 模板（仅 SETUP_FAIL2BAN=1 时安装）
scripts/init_server.sh       安装 docker；可选安装 ufw/fail2ban
scripts/firewall_setup.sh    ufw 规则（仅 SETUP_FIREWALL=1 时调用）
scripts/gen_cert.sh          自签证书生成
scripts/token_manager.sh     Token 管理包装脚本
tests/validate.sh            自检脚本
```

## 3. 服务器要求

- Linux（Ubuntu/Debian/CentOS/RHEL/Rocky/Alma/Fedora/Amazon Linux）
- root 权限、可访问外网（用于安装 docker 与镜像）
- 至少放通 80、443；SSH 端口保持可用

## 4. 一键部署

```bash
sudo bash deploy.sh
```

脚本按顺序完成：

1. 初始化服务器环境：只强制安装/启动 docker 与基础依赖（openssl、python3）；
2. 生成 `.env`（自动 `openssl rand -hex 32` 生成 `SECRET_KEY`，权限 600）；
3. 证书不存在时生成自签证书到 `certs/`；
4. 首次部署自动创建一个 `bootstrap` 访问令牌并打印；
5. `docker compose up -d --build`，轮询等待 `safe-nginx` 变为 healthy。

防火墙与 fail2ban **默认不处理**。需要本项目代管时，在 `.env` 中设置：

```bash
SETUP_FIREWALL=1   # 安装 ufw，默认拒绝入站，仅放行 SSH/80/443
SETUP_FAIL2BAN=1   # 安装 fail2ban，匹配 AUTH_DROP 日志在 DOCKER-USER 链封禁 80/443
```

也可以临时通过环境变量开启：

```bash
sudo SETUP_FIREWALL=1 SETUP_FAIL2BAN=1 bash deploy.sh
```

可配置的环境变量（写入 `.env`）：

| 变量 | 默认值 | 说明 |
| --- | --- | --- |
| `SECRET_KEY` | 自动生成 | 会话 Cookie 签名密钥，禁止泄露 |
| `APP_IMAGE` | `safe-app:local` | 业务镜像名 |
| `PYTHON_IMAGE` | `python:3.11-slim` | app/auth 构建的基础镜像，可换成镜像站地址 |
| `NGINX_IMAGE` | `nginx:1.27-alpine` | nginx 镜像，可换成镜像站地址 |
| `DOMAIN` | `localhost` | 证书 SAN 与访问域名 |
| `SESSION_TTL` | `28800` | 会话有效期（秒） |
| `FAIL_WINDOW` | `600` | 无 token 访问计数窗口（秒） |
| `MAX_FAILS` | `3` | 窗口内允许的无 token 访问次数 |
| `SETUP_FIREWALL` | `0` | 1=由本项目配置 ufw |
| `SETUP_FAIL2BAN` | `0` | 1=由本项目配置 fail2ban |
| `SETUP_DOCKER_MIRROR` | `0` | 1=写入 `/etc/docker/daemon.json` 镜像加速并重启 docker |
| `DOCKER_REGISTRY_MIRRORS` | `https://docker.m.daocloud.io,https://dockerproxy.net` | 逗号分隔的 registry-mirrors |

## 4.1 Docker 镜像源无法使用

如果 `docker pull` 或 `docker compose build` 拉取 `python:3.11-slim`、`nginx:1.27-alpine` 超时/被拒，按下面任一方式处理。

### 方式一：配置 daemon 镜像加速（推荐先试）

在 `.env` 中打开开关，并填入你所在网络可用的镜像站：

```bash
SETUP_DOCKER_MIRROR=1
DOCKER_REGISTRY_MIRRORS=https://docker.m.daocloud.io,https://dockerproxy.net
```

然后重新执行 `sudo bash deploy.sh`。`init_server.sh` 会调用
`scripts/docker_mirror.sh`：备份原 `/etc/docker/daemon.json`，写入 `registry-mirrors`，重启 docker。

> 镜像站可用性会变化，请以你所在网络实测为准；多个地址用英文逗号分隔。
> 若 `daemon.json` 原本不是合法 JSON，脚本会中止且不改动原文件。

### 方式二：直接替换镜像地址（最可靠）

不改 daemon，直接把镜像前缀换成可访问的镜像站：

```bash
# .env
PYTHON_IMAGE=docker.m.daocloud.io/library/python:3.11-slim
NGINX_IMAGE=docker.m.daocloud.io/library/nginx:1.27-alpine
```

镜像地址会通过 compose 的 `build.args` 传给所有 Dockerfile 的 `FROM`，
也会替换 `nginx` 服务的 `image`，无需改动任何 Dockerfile。

### 方式三：离线导入镜像

在可联网的机器上拉取并导出，再拷到服务器导入：

```bash
# 有网机器
docker pull python:3.11-slim
docker pull nginx:1.27-alpine
docker save -o images.tar python:3.11-slim nginx:1.27-alpine

# 服务器
docker load -i images.tar
```

导入后保持 `PYTHON_IMAGE`/`NGINX_IMAGE` 为默认值即可，构建时直接命中本地镜像。

## 5. 授权访问

首次登录（浏览器，成功后写入会话 Cookie）：

```
https://<server>/auth/login?token=<TOKEN>
```

接口调用（每次请求携带 token）：

```bash
curl -k -H "X-Auth-Token: <TOKEN>" https://<server>/
```

访问控制行为：

| 场景 | 结果 |
| --- | --- |
| 有效 token 或有效会话 Cookie | 放行，并清零该 IP 的失败计数 |
| 无 token / 错误 token，且窗口内次数 ≤ `MAX_FAILS` | `401 {"error":"unauthorized", ...}` 提示如何授权 |
| 无 token / 错误 token，且窗口内次数 > `MAX_FAILS` | nginx `return 444`：直接关闭连接，不返回任何响应 |
| 计数窗口（`FAIL_WINDOW`）滑过 | 计数自动清零，恢复 401 提示 |

说明：超频忽略只针对"无有效凭据"的访问；持有有效 token 的请求始终放行。该策略不写入持久黑名单，窗口结束自动恢复，避免误伤。

## 6. 令牌与计数管理

```bash
# 新增令牌（明文只显示一次）
sudo bash scripts/token_manager.sh add alice-laptop

# 查看令牌（不显示明文）
sudo bash scripts/token_manager.sh list

# 吊销令牌
sudo bash scripts/token_manager.sh revoke alice-laptop

# 清零某个 IP 的失败计数（解除超频忽略）
sudo bash scripts/token_manager.sh reset 203.0.113.10
```

## 7. 示例应用部署样板

`examples/` 提供完整的示例应用与接入样板：

```bash
# 用样板应用替换默认 demo
COMPOSE_FILE=docker-compose.yml:examples/compose.override.yml \
  docker compose up -d --build
```

接入约定：容器内监听 `8080`、提供 `GET /healthz`、只用 `expose` 不写 `ports`、只加入 `internal` 网络、非 root 运行。详见 `examples/README.md`。

替换为真实应用时：

1. 修改 `docker-compose.yml` 中 `app` 服务的 `image`（或保留 `build` 指向自己的构建目录），并把 `APP_IMAGE` 写入 `.env`；
2. 确认应用满足上述接入约定；
3. 重新执行 `sudo bash deploy.sh`（或 `docker compose up -d --build`）。

## 8. 证书

- 默认生成 825 天自签证书，仅适合内网/测试；
- 公网部署请将正式证书放到 `certs/fullchain.pem` 与 `certs/privkey.pem`（私钥 `chmod 600`），再 `docker compose restart nginx`；
- 80 端口已预留 `/.well-known/acme-challenge/` 路径，可直接对接 certbot。

## 9. 自检

本地无需 docker 即可校验配置与逻辑：

```bash
bash tests/validate.sh
```

包含：shell 语法检查、Python 编译检查、鉴权单元测试、真实 HTTP 集成测试（401 提示、有效 token 放行、Cookie 复用、超频后静默拒绝、跨 IP 隔离）、compose YAML 校验、fail2ban filter 格式校验。全部通过时输出 `validation PASSED`。

## 10. 常用运维命令

```bash
docker compose ps                        # 服务状态
docker compose logs -f nginx             # 网关日志
docker compose logs -f auth              # 鉴权日志
tail -f data/auth.log                    # 鉴权明细（含 AUTH_FAIL / AUTH_DROP）
ufw status verbose                       # 防火墙状态（若自行启用）
fail2ban-client status auth-gateway      # fail2ban 状态（若自行启用）
```

## 11. 安全注意事项

- `.env`、`data/`、`certs/` 已在 `.gitignore` 中排除，切勿提交；
- 定期轮换 `SECRET_KEY`（会使所有会话失效）与业务令牌；
- 不要把 token 放在可被日志记录的 URL 中，接口调用优先使用 `X-Auth-Token`；
- 防火墙与 fail2ban 默认关闭，请根据服务器实际情况自行配置，或在 `.env` 中显式开启；
- 建议在云安全组再叠加一层仅放行 80/443/SSH 的规则；
- 生产环境建议把 nginx 的 `limit_req` 速率、`FAIL_WINDOW`、`MAX_FAILS` 按实际流量调整。
