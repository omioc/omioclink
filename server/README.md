# OmiocLink 服务端

<p><b>语言 / Languages:</b> <a href="README.md">中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

FastAPI 信令服务器 + STUN + Web 管理台

**只做信令与状态，永不转发媒体**：语音、屏幕、聊天都在成员之间直连（WebRTC + DTLS-SRTP），服务端没有 TURN、没有 relay 进程，流量永远 KB 级

- 对外只有 `21077`（HTTP + WebSocket）与可选的 `3478/udp`（自建 STUN）
- 数据只有一个卷：`omioclink_server-data` → `/app/data`（SQLite + 头像 + 插件订阅），备份把卷拿走即可
- 两种部署方式项目名都叫 `omioclink`，数据卷同名，**可以互相切换、数据不用搬**

---

## 一、在线部署

前提：需要一台有公网 IPv4 的 Linux，装好 Docker 与 compose 插件，且能够连通 github 和 Docker hub：

```bash
curl -fsSL https://raw.githubusercontent.com/omioc/omioclink/main/deploy/install.sh -o /tmp/omioc-install.sh && sudo bash /tmp/omioc-install.sh
```

- 默认装到 `/opt/omioc_server`（`--dir` 可改），全程日志在 `<安装目录>/deploy-<日期>.log`
- 幂等：中断或换参数后重跑同一条命令即可，已完成的步骤自动跳过（`.env` 不覆盖、密钥不重生）

---

## 二、离线部署

### 方式一：从项目下载 tar 包离线部署

下载镜像包：

[x86 架构](https://github.com/omioc/omioclink/releases/latest/download/omioclink-server-1.0.8-amd64.tar) | 
[arm 架构](https://github.com/omioc/omioclink/releases/latest/download/omioclink-server-1.0.8-arm64.tar)

```bash
# 1. 上传镜像包至服务器，使用 docker load -i <image-name>.tar 导入镜像
# 2. 拷贝本项目根目录的 deploy 文件夹至服务器
cd deploy
cp .env.example .env
# 可选：OMIOCLINK_JWT_SECRET 留空由服务端自动生成并持久化；管理台第一次打开时设置管理员密码
# 若开启 stun，则需要根据实际情况为 OMIOCLINK_ICE_SERVERS 填写值 —— stun:<公网 IP / 域名>:3478
docker compose --profile stun up -d
docker ps
```

### 方式二：自行构建镜像并离线部署

```bash
git clone https://github.com/omioc/omioclink.git
cd omioclink/server

docker build -t omioc/omioclink:latest .

# 2. 导出 tar：版本取自 pyproject.toml，架构跟构建机一致
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
docker save omioc/omioclink:latest -o "omioclink-server-${VERSION}-${ARCH}.tar"
```

产物是当前目录下的 `omioclink-server-<版本>-<架构>.tar`，之后的步骤和方式一一致

构建时依赖源默认走清华镜像，要官方源就把 build 那行换成`docker build --build-arg PIP_INDEX_URL=https://pypi.org/simple -t omioc/omioclink:latest .`

---

## 三、环境变量

全部变量前缀 `OMIOCLINK_`，可以写在 `.env`，也可以直接 `export`

完整清单与默认值见 [`app/core/config.py`](app/core/config.py)，下表是部署时要动的：

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `OMIOCLINK_JWT_SECRET` | 空（自动生成） | HS256 签名密钥；**留空即自动生成**并持久化到数据卷的 `jwt-secret` 文件，指定时至少 32 字节 |
| `OMIOCLINK_ADMIN_TOKEN` | 空 | **已废弃**：管理台改用管理员密码登录；这个值只在还没设置管理员密码时能当过渡令牌用 |
| `OMIOCLINK_ADMIN_SESSION_TTL_SECONDS` | `43200`（12 小时） | 管理台登录态有效期；改密码会让所有旧登录态立即失效 |
| `OMIOCLINK_ALLOW_REGISTRATION` | `false` | 是否允许自行注册；也可在管理台临时切换（重启后回到这里的值） |
| `OMIOCLINK_DOCS_ENABLED` | `false` | 是否暴露 `/docs` 与 `/openapi.json`（会把整个 API 面对外公开） |
| `OMIOCLINK_ICE_SERVERS` | `stun:stun.cloudflare.com:3478` | 下发给客户端的 STUN 列表，逗号分隔或 JSON 数组；**只填 `stun:`，本项目不支持 TURN** |
| `OMIOCLINK_BIND_ADDR` | `0.0.0.0` | 只影响 compose 的端口绑定地址；挂 TLS 反代时收紧成 `127.0.0.1` |
| `OMIOCLINK_CORS_ORIGINS` | `*` | 允许的跨域来源（客户端是桌面/手机应用，不经浏览器同源策略，按需收紧） |
| `OMIOCLINK_MUSIC_ENABLED` | `true` | 点歌台总开关（关掉后客户端不显示入口） |
| `OMIOCLINK_AVATAR_MAX_BYTES` | `2097152` | 单张头像字节上限（客户端会先缩到 256px，正常只有几十 KB） |
| `OMIOCLINK_DATABASE_URL` | compose 固定 `sqlite+aiosqlite:////app/data/omioclink.db` | 库文件落在数据卷里 |
| `OMIOCLINK_DATA_DIR` | compose 固定 `/app/data` | 头像等文件的落点（`<data_dir>/avatars/`） |
| `OMIOCLINK_IMAGE` | `omioc/omioclink:latest` | 仅 compose 用：固定版本/回滚时改成带 tag 的镜像 |
| `OMIOCLINK_PIP_INDEX_URL` | 清华 PyPI 镜像 | 只对 `server/docker-compose.yml` 的 `--build` 有效：构建时装依赖的源 |

心跳与房间容量的默认值（`OMIOCLINK_HEARTBEAT_INTERVAL_SECONDS=30`、`..._TIMEOUT_SECONDS=90`、
`OMIOCLINK_DEFAULT_ROOM_CAPACITY=5`、`OMIOCLINK_MAX_ROOM_CAPACITY=8`）一般不用改

---

## 四、目录结构

| 路径 | 内容 |
| --- | --- |
| `app/` | FastAPI 应用：`api/`（REST）、`signaling/`（WebSocket 协议、房间与成员状态）、`stun/`（地址回显）、`db/`、`services/` |
| `tests/` | pytest 用例（`uv run pytest`） |
| `Dockerfile` | 单阶段精简镜像，非 root（`omioclink:omioclink`）运行，内置健康检查 |
| `docker-compose.yml` | **离线部署**：从本目录 `Dockerfile` 本地构建 `omioc/omioclink:latest` 再导出为 tar 上传到服务器部署 |
| `tool/export_image.ps1` | 把镜像导出成离线 tar（`releases/server-v<版本>/`），版本取自 `pyproject.toml` |
| `../deploy/` | **在线部署**：只拉 Docker Hub 上的 `omioc/omioclink:latest`，无需构建 |

---

## 五、对外接口

| 路径 | 说明 |
| --- | --- |
| `GET /api/v1/health` | 健康检查；Dockerfile 的 `HEALTHCHECK` 也打它，`docker ps` 里的 healthy 就是它说了算 |
| `GET /api/v1/server/info` | 服务器能力与下发配置（名称、版本、注册开关、房间容量、ICE/STUN 列表） |
| `WS /ws` | 信令：进房/离房、成员状态、`offer`/`answer`/`candidate` 转发、应用层心跳与时钟同步 |
| `GET /admin` | Web 管理台，**始终可用**：第一次打开时要求设置管理员密码 |
| `GET /api/v1/admin/*` | 管理接口（`Authorization: Bearer` + 管理员密码换来的令牌）；老部署的 `X-Admin-Token` 只在设置密码前可用 |
| `GET /docs`、`/openapi.json` | Swagger UI 与 OpenAPI 描述，**仅在 `OMIOCLINK_DOCS_ENABLED=true` 时注册**，不建议开启 |

端口：

| 端口 | 用途 | 暴露方式 |
| --- | --- | --- |
| `21077/tcp` | 主服务（REST + WebSocket） | compose 端口映射，可收紧成只给反代 |
| `3478/udp` | 可选的自建 STUN | 只在开 `--profile stun` 时启动，且必须 `network_mode: host` |

---

## 六、自建 STUN（可选，推荐）

公共 STUN（`stun.l.google.com` 等）在国内可达性不稳定，自建最稳：

```bash
cd deploy
docker compose --profile stun up -d
```

然后把 `.env` 里的 `OMIOCLINK_ICE_SERVERS` 指向它，例如：

```
OMIOCLINK_ICE_SERVERS=stun:<你的公网 IP / 域名>:3478
```

改完 `docker compose up -d` 重建一次容器（环境变量在启动时读入）

**必须 `network_mode: host`**：STUN 要如实回显「客户端看到的来源地址」

它只回答「你的公网映射地址是什么」，和信令同属"连接发现"，**不转发任何媒体** —— 不是中继，也不替代 TURN

---

## 七、Web 管理台

1. `docker compose up -d`（**不用配任何密钥**），浏览器打开 `http://<服务器 IP / 域名>:21077/admin`
2. 第一次打开会弹「设置管理员密码」，设完自动登录；密码只存 bcrypt 哈希（`admin_account` 表）
3. 再打开就是密码登录；右上角可改密码（改完其他浏览器的登录态立即失效）或退出

四个区块：

- **用户自注册**：临时开关（不写库，重启后回到 `.env` 的值）
- **房间**：在线房间列表、人数上限、当前成员，可把成员移出、解散房间
- **账号**：按用户名/昵称搜索，新建、禁用/启用、删除
- **音乐插件订阅**：维护下发给客户端的插件订阅地址（`.json` 清单或 `.js` 直链），客户端连上服务器后自动同步、
  按 `sha256` 判断是否需要重装

> 密码忘了：删掉库里那一行再重设 ——
> `docker compose exec server python -c "import sqlite3; c=sqlite3.connect('/app/data/omioclink.db'); c.execute('DELETE FROM admin_account'); c.commit()"`

> **从老版本升级**（`.env` 里还有 `OMIOCLINK_ADMIN_TOKEN`）：页面同样会弹「设置管理员密码」。
> 设置之前旧令牌仍可用（`X-Admin-Token`，方便过渡期的脚本），设置完立即作废——之后把 `.env` 里那一行删掉即可。

> 管理台是对外开放的：第一次部署完请**尽快**把管理员密码设好，别把「设置密码」的界面晾在公网上。
> 只想内网用的话，把 `21077` 收到反代后面，或设置 `OMIOCLINK_BIND_ADDR=127.0.0.1`。

> 「设置密码 / 登录」这两个接口只接受**同源**页面发来的请求（`Sec-Fetch-Site` + `Origin`/`Host` 双重判断），
> 免得别的网站借访客浏览器把管理员密码设掉。反代只要别把浏览器的请求变成跨站就能正常用
> （现代浏览器都带 `Sec-Fetch-Site`，不受 Host 改写影响）。

> **登录限流**（防止在线猜密码）：管理台同一 IP 连错 5 次锁 5 分钟（锁定期间连正确密码也不放行）；
> 客户端账号连续输错后指数退避（前 3 次只是普通报错，之后 2s → 4s → … 封顶 60s）；
> 同一 IP 每 5 分钟最多 10 次登录请求。计数在进程内存里，重启清零（单容器部署够用）。
>
> **登录记录**：每次尝试（客户端 / 管理台、成功 / 失败）都落一条，含用户名、来源 IP、
> User-Agent 与成败，保留 30 天（`login_records` 表）。管理页界面暂未接这块，先用接口看：
>
> ```bash
> curl -H "Authorization: Bearer <管理台令牌>" \
>   "http://127.0.0.1:21077/api/v1/admin/logins?onlyFailed=true&limit=20"
> ```
>
> 反代后面部署时，来源 IP 取 `X-Forwarded-For` 的第一段——但**只在直连对端是内网/回环时**
> 才信任这个头，公网直连伪造它绕不过限流。

> 想开一批账号：`.env` 里 `OMIOCLINK_ALLOW_REGISTRATION=true` → `docker compose up -d` → 客户端自助注册 → 再改回 `false` 并 `up -d`；或者由管理员在控制台建立账号，注册开关保持关闭

---

## 八、在线调试

### 本地把服务跑起来，改代码即时生效

```bash
cd server
uv sync
uv run uvicorn app.main:app --host 0.0.0.0 --port 21077 --reload
```

- `--reload` 改一行存一次就自动重启，客户端可以直接连本机 `127.0.0.1:21077`
- 想看接口文档：`OMIOCLINK_DOCS_ENABLED=true uv run uvicorn app.main:app --port 21077 --reload`，
  然后开 `http://127.0.0.1:21077/docs`
- 冒烟：`curl http://127.0.0.1:21077/api/v1/health`、`curl http://127.0.0.1:21077/api/v1/server/info`
- 本地管理台：直接开 `http://127.0.0.1:21077/admin`，第一次会要求设置管理员密码（密码存在 `./omioclink.db`）

> 本机跑的时候数据库为 `./omioclink.db`、数据目录是 `./data`（见 `config.py` 默认值），和容器里的 `/app/data` 互不影响

### 排查线上容器

```bash
docker compose ps                     # 看 healthy 还是 unhealthy
docker compose logs -f server         # 跟着看日志（uvicorn 访问日志 + 未处理异常堆栈）
docker compose exec server python -c "import app; print(app.__version__)"   # 容器里实际是哪个版本
docker compose exec server ls -l /app/data                                  # 数据卷挂上了没
```

- 事件循环疑似卡住时，用 `OMIOCLINK_DEBUG_TASKS=1` 起容器：会每 0.5 秒把事件循环里所有任务的
  文件名:行号:函数打一份到标准输出（排查"接口不返回、日志没动静"这类挂起最直接）
- 容器以非 root 用户 `omioclink` 运行，`exec` 进去也是它；改文件、装包请改 Dockerfile

---

## 九、测试与静态检查

```bash
cd server
uv run pytest                # 用例（单例 20s 超时，卡死会以失败+堆栈形式暴露）
uv run ruff check .          # 静态检查（行宽 100，规则见 pyproject）
uv run mypy                  # 类型检查（strict）
```

三条都必须干净。CI 在每次 push 与 PR 上跑同样的三件事，外加版本号漂移检查

---

## 十、数据、备份与升级

| 项 | 值 |
| --- | --- |
| 数据卷 | `omioclink_server-data` → `/app/data` |
| 里面是什么 | `omioclink.db`（SQLite：账号、好友、房间、插件订阅、管理员密码哈希）+ `avatars/` + `jwt-secret`（服务端自动生成的签名密钥） |
| 备份 | 把卷打包即可（示例，任选基础镜像）：`docker run --rm -v omioclink_server-data:/data -v "$PWD":/backup alpine tar czf /backup/omioclink-data.tgz -C /data .` |
| 恢复 | 反着来：`docker run --rm -v omioclink_server-data:/data -v "$PWD":/backup alpine tar xzf /backup/omioclink-data.tgz -C /data` |
| 升级 | `docker compose pull && docker compose up -d`（离线环境用方式 B 重新导入 tar） |
| 回滚 | `.env` 里 `OMIOCLINK_IMAGE=omioc/omioclink:v<旧版本>` → `docker compose up -d` |

头像和 SQLite 在同一个卷里，所以备份一次就是全量；`down -v` 会删卷，别在没备份时敲

---

## 十一、常见问题

| 现象 | 原因 / 处理 |
| --- | --- |
| `docker compose up` 报「请在 .env 里设置 OMIOCLINK_JWT_SECRET」 | 那是老版本（1.0.5 及更早）。新版留空即可：服务端会自动生成密钥并存到数据卷的 `jwt-secret` |
| `/admin` 打开要求设置密码 | 正常：管理台第一次使用要设管理员密码（以前是填令牌），设完就能登录 |
| 管理台密码忘了 | 删掉库里的 `admin_account` 那一行再重设（第七节有命令） |
| 老 `.env` 里的 `OMIOCLINK_ADMIN_TOKEN` 还能用吗 | 能在「设置管理员密码」之前当过渡令牌用；设置完就作废，之后把那行删掉即可 |
| `/docs` 打开是 404 | `OMIOCLINK_DOCS_ENABLED=false`（默认值），调试时临时设为 `true` |
| `docker ps` 里是 `unhealthy` | 多半是数据库/数据目录权限或 JWT 密钥不合规，先看 `docker compose logs server` |
| 客户端连不上、容器却是 healthy | 放行 TCP `21077`；走域名+反代时确认 `OMIOCLINK_BIND_ADDR` 与反代指向一致；用 `http/ws` 明文要客户端允许明文 |
| 能连上但语音打洞失败 | 这是"无中继"架构的代价，与服务器无关：对称型 NAT、封 UDP 的网络会失败；先开自建 STUN（第六节），再按客户端提示换网络 |
| 改了 `.env` 不生效 | 环境变量在容器启动时读入，改完要 `docker compose up -d` 重建 |
| 想改监听端口 | `ports` 写在 `deploy/docker-compose.yml` 与 `server/docker-compose.yml` 里（左右两侧一起改），客户端填 `<host>:<port>` |
