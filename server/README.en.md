# OmiocLink Server

<p><b>语言 / Languages:</b> <a href="README.md">中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

FastAPI signaling server + STUN + web admin console

**Signaling and state only, media is never relayed**: voice, screen sharing, and chat all connect directly between members (WebRTC + DTLS-SRTP); the server has no TURN and no relay process, so traffic always stays in the KB range

- Only `21077` (HTTP + WebSocket) and an optional `3478/udp` (self-hosted STUN) are exposed
- A single data volume: `omioclink_server-data` → `/app/data` (SQLite + avatars + plugin subscriptions); back it up by taking the volume
- Both deployment methods use the project name `omioclink` and the same data volume name, so **you can switch between them without moving any data**

---

## 1. Online deployment

Prerequisites: a Linux host with a public IPv4 address, Docker and the compose plugin installed, and outbound access to GitHub and Docker Hub:

```bash
curl -fsSL https://raw.githubusercontent.com/omioc/omioclink/main/deploy/install.sh -o /tmp/omioc-install.sh && sudo bash /tmp/omioc-install.sh
```

- Installs to `/opt/omioc_server` by default (change it with `--dir`); the full log is written to `<install dir>/deploy-<date>.log`
- Idempotent: if it is interrupted or you change flags, just rerun the same command — completed steps are skipped automatically (`.env` is not overwritten, keys are not regenerated)

---

## 2. Offline deployment

### Option 1: download the tar package from the project and deploy offline

Download the image package:

[x86 architecture](https://github.com/omioc/omioclink/releases/latest/download/omioclink-server-1.0.8-amd64.tar) | 
[arm architecture](https://github.com/omioc/omioclink/releases/latest/download/omioclink-server-1.0.8-arm64.tar)

```bash
# 1. Upload the image package to the server and import it with docker load -i <image-name>.tar
# 2. Copy the deploy folder from the project root to the server
cd deploy
cp .env.example .env
# Optional: leave OMIOCLINK_JWT_SECRET empty and the server generates and persists it; set the admin password the first time you open the admin console
# If STUN is enabled, fill in OMIOCLINK_ICE_SERVERS to match your setup — stun:<public IP / domain>:3478
docker compose --profile stun up -d
docker ps
```

### Option 2: build the image yourself and deploy offline

```bash
git clone https://github.com/omioc/omioclink.git
cd omioclink/server

docker build -t omioc/omioclink:latest .

# 2. Export the tar: the version comes from pyproject.toml, the architecture matches the build machine
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
docker save omioc/omioclink:latest -o "omioclink-server-${VERSION}-${ARCH}.tar"
```

The artifact is `omioclink-server-<version>-<arch>.tar` in the current directory; the remaining steps are the same as for option 1

Builds pull dependencies from the Tsinghua mirror by default; for the official index, replace the build line with `docker build --build-arg PIP_INDEX_URL=https://pypi.org/simple -t omioc/omioclink:latest .`

---

## 3. Environment variables

Every variable is prefixed with `OMIOCLINK_`; set them in `.env` or `export` them directly

The full list with defaults is in [`app/core/config.py`](app/core/config.py); the table below covers the ones you change when deploying:

| Variable | Default | Description |
| --- | --- | --- |
| `OMIOCLINK_JWT_SECRET` | empty (auto-generated) | HS256 signing key; **leave it empty and one is generated automatically** and persisted to the `jwt-secret` file in the data volume. If you set it, use at least 32 bytes |
| `OMIOCLINK_ADMIN_TOKEN` | empty | **Deprecated**: the admin console now logs in with an admin password; this value only works as a transitional token before an admin password has been set |
| `OMIOCLINK_ADMIN_SESSION_TTL_SECONDS` | `43200` (12 hours) | Admin console session lifetime; changing the password immediately invalidates every existing session |
| `OMIOCLINK_ALLOW_REGISTRATION` | `false` | Whether self-registration is allowed; can also be toggled temporarily in the admin console (a restart reverts to the value here) |
| `OMIOCLINK_DOCS_ENABLED` | `false` | Whether to expose `/docs` and `/openapi.json` (this publishes the entire API surface) |
| `OMIOCLINK_ICE_SERVERS` | `stun:stun.cloudflare.com:3478` | STUN list handed down to clients, comma-separated or a JSON array; **`stun:` entries only — this project does not support TURN** |
| `OMIOCLINK_BIND_ADDR` | `0.0.0.0` | Only affects the compose port binding address; tighten it to `127.0.0.1` when running behind a TLS reverse proxy |
| `OMIOCLINK_CORS_ORIGINS` | `*` | Allowed cross-origin origins (the client is a desktop/mobile app and does not go through the browser same-origin policy; tighten as needed) |
| `OMIOCLINK_MUSIC_ENABLED` | `true` | Master switch for the song request plugin (when off, the client hides the entry point) |
| `OMIOCLINK_AVATAR_MAX_BYTES` | `2097152` | Byte limit for a single avatar (the client downscales to 256px first, so files are normally a few tens of KB) |
| `OMIOCLINK_DATABASE_URL` | fixed by compose to `sqlite+aiosqlite:////app/data/omioclink.db` | The database file lives in the data volume |
| `OMIOCLINK_DATA_DIR` | fixed by compose to `/app/data` | Where avatars and other files land (`<data_dir>/avatars/`) |
| `OMIOCLINK_IMAGE` | `omioc/omioclink:latest` | Compose only: pin a tagged image here to lock a version or roll back |
| `OMIOCLINK_PIP_INDEX_URL` | Tsinghua PyPI mirror | Only effective for `--build` in `server/docker-compose.yml`: the index used to install dependencies at build time |

The heartbeat and room capacity defaults (`OMIOCLINK_HEARTBEAT_INTERVAL_SECONDS=30`, `..._TIMEOUT_SECONDS=90`,
`OMIOCLINK_DEFAULT_ROOM_CAPACITY=5`, `OMIOCLINK_MAX_ROOM_CAPACITY=8`) usually need no change

---

## 4. Directory layout

| Path | Contents |
| --- | --- |
| `app/` | FastAPI application: `api/` (REST), `signaling/` (WebSocket protocol, room and member state), `stun/` (address echo), `db/`, `services/` |
| `tests/` | pytest cases (`uv run pytest`) |
| `Dockerfile` | Single-stage slim image, runs as non-root (`omioclink:omioclink`), health check built in |
| `docker-compose.yml` | **Offline deployment**: builds `omioc/omioclink:latest` locally from the `Dockerfile` in this directory, then exports it as a tar to upload and deploy on the server |
| `tool/export_image.ps1` | Exports the image to an offline tar (`releases/server-v<version>/`); the version comes from `pyproject.toml` |
| `../deploy/` | **Online deployment**: pulls only `omioc/omioclink:latest` from Docker Hub, no build required |

---

## 5. Exposed interfaces

| Path | Description |
| --- | --- |
| `GET /api/v1/health` | Health check; the Dockerfile `HEALTHCHECK` calls it too, so what `docker ps` reports as healthy is up to it |
| `GET /api/v1/server/info` | Server capabilities and pushed-down configuration (name, version, registration switch, room capacity, ICE/STUN list) |
| `WS /ws` | Signaling: join/leave room, member state, `offer`/`answer`/`candidate` forwarding, application-level heartbeat and clock sync |
| `GET /admin` | Web admin console, **always available**: the first visit asks you to set an admin password |
| `GET /api/v1/admin/*` | Admin API (`Authorization: Bearer` plus a token exchanged for the admin password); `X-Admin-Token` from older deployments only works before a password is set |
| `GET /docs`, `/openapi.json` | Swagger UI and the OpenAPI description, **registered only when `OMIOCLINK_DOCS_ENABLED=true`**; not recommended |

Ports:

| Port | Purpose | Exposure |
| --- | --- | --- |
| `21077/tcp` | Main service (REST + WebSocket) | Compose port mapping; can be narrowed to the reverse proxy only |
| `3478/udp` | Optional self-hosted STUN | Started only with `--profile stun`, and requires `network_mode: host` |

---

## 6. Self-hosted STUN (optional, recommended)

Public STUN servers (`stun.l.google.com` and others) are not reliably reachable from mainland China, so self-hosting is the most stable option:

```bash
cd deploy
docker compose --profile stun up -d
```

Then point `OMIOCLINK_ICE_SERVERS` in `.env` at it, for example:

```
OMIOCLINK_ICE_SERVERS=stun:<your public IP / domain>:3478
```

After the change, recreate the container once with `docker compose up -d` (environment variables are read at startup)

**`network_mode: host` is mandatory**: STUN has to report the "source address the client sees" truthfully

It only answers "what is my public mapped address"; together with signaling it belongs to connection discovery, and it **never relays any media** — it is not a relay, and it does not replace TURN

---

## 7. Web admin console

1. `docker compose up -d` (**no key of any kind to configure**), then open `http://<server IP / domain>:21077/admin` in a browser
2. The first visit shows "set the admin password"; once set you are logged in automatically, and only the bcrypt hash is stored (the `admin_account` table)
3. Later visits use password login; the top-right corner lets you change the password (after which sessions in other browsers are invalidated immediately) or log out

Four sections:

- **User self-registration**: a temporary switch (not written to the database; after a restart it returns to the `.env` value)
- **Rooms**: online room list, capacity, current members; you can remove members and close rooms
- **Accounts**: search by username/nickname, create, disable/enable, delete
- **Music plugin subscriptions**: maintain the plugin subscription addresses handed down to clients (a `.json` manifest or a `.js` direct link); clients sync automatically once connected and
  use `sha256` to decide whether a reinstall is needed

> Forgot the password: delete that row in the database and set it again —
> `docker compose exec server python -c "import sqlite3; c=sqlite3.connect('/app/data/omioclink.db'); c.execute('DELETE FROM admin_account'); c.commit()"`

> **Upgrading from an old version** (`.env` still has `OMIOCLINK_ADMIN_TOKEN`): the page still asks you to set the admin password.
> Until you do, the old token keeps working (`X-Admin-Token`, which is handy for transition scripts); it is invalidated the moment you set the password — after that, delete that line from `.env`.

> The admin console is exposed to the internet: set the admin password **as soon as possible** after the first deployment, and do not leave the "set password" screen sitting on the public internet.
> If you only need it on an internal network, put `21077` behind a reverse proxy, or set `OMIOCLINK_BIND_ADDR=127.0.0.1`.

> The "set password / login" endpoints only accept requests from **same-origin** pages (a double check of `Sec-Fetch-Site` plus `Origin`/`Host`),
> so no other site can use a visitor's browser to set the admin password. A reverse proxy works fine as long as it does not turn
> browser requests into cross-site ones (modern browsers all send `Sec-Fetch-Site`, and it is not affected by Host rewriting).

> **Login rate limiting** (to stop online password guessing): five consecutive failures from the same IP lock the admin console for 5 minutes (even the correct password is rejected while locked);
> client accounts back off exponentially after consecutive wrong entries (the first 3 are plain errors, then 2s → 4s → … capped at 60s);
> the same IP gets at most 10 login requests per 5 minutes. Counters live in process memory and reset on restart (good enough for a single-container deployment).
>
> **Login records**: every attempt (client / admin console, success / failure) is stored with the username, source IP,
> User-Agent and outcome, and kept for 30 days (the `login_records` table). The admin UI does not cover this yet; use the API for now:
>
> ```bash
> curl -H "Authorization: Bearer <admin console token>" \
>   "http://127.0.0.1:21077/api/v1/admin/logins?onlyFailed=true&limit=20"
> ```
>
> When deployed behind a reverse proxy, the source IP is the first entry of `X-Forwarded-For` — but that header is trusted
> **only when the direct peer is a private or loopback address**; forging it on a direct public connection does not get around the rate limit.

> To open a batch of accounts: set `OMIOCLINK_ALLOW_REGISTRATION=true` in `.env` → `docker compose up -d` → users register themselves from the client → set it back to `false` and run `up -d` again; or create the accounts in the console as an admin and leave registration off

---

## 8. Debugging

### Run the service locally and pick up code changes immediately

```bash
cd server
uv sync
uv run uvicorn app.main:app --host 0.0.0.0 --port 21077 --reload
```

- With `--reload`, every saved line restarts the server automatically, and the client can connect straight to `127.0.0.1:21077` on the local machine
- To read the API docs: `OMIOCLINK_DOCS_ENABLED=true uv run uvicorn app.main:app --port 21077 --reload`,
  then open `http://127.0.0.1:21077/docs`
- Smoke test: `curl http://127.0.0.1:21077/api/v1/health`, `curl http://127.0.0.1:21077/api/v1/server/info`
- Local admin console: open `http://127.0.0.1:21077/admin` directly; the first visit asks you to set an admin password (the password is stored in `./omioclink.db`)

> When running locally the database is `./omioclink.db` and the data directory is `./data` (see the defaults in `config.py`); neither affects `/app/data` in the container

### Troubleshooting a live container

```bash
docker compose ps                     # healthy or unhealthy
docker compose logs -f server         # follow the logs (uvicorn access log + unhandled exception traces)
docker compose exec server python -c "import app; print(app.__version__)"   # which version the container actually runs
docker compose exec server ls -l /app/data                                  # is the data volume mounted
```

- If the event loop looks stuck, start the container with `OMIOCLINK_DEBUG_TASKS=1`: every 0.5s it dumps every task in the event loop
  to stdout as file:line:function (the most direct way to diagnose hangs where "the API does not answer and the logs say nothing")
- The container runs as the non-root user `omioclink`, and `exec` gets you that same user; to change files or install packages, change the Dockerfile

---

## 9. Tests and static checks

```bash
cd server
uv run pytest                # tests (20s timeout per case; a hang surfaces as a failure plus stack trace)
uv run ruff check .          # static checks (line width 100, rules in pyproject)
uv run mypy                  # type checking (strict)
```

All three must be clean. CI runs the same three on every push and PR, plus a version drift check

---

## 10. Data, backup, and upgrade

| Item | Value |
| --- | --- |
| Data volume | `omioclink_server-data` → `/app/data` |
| What is inside | `omioclink.db` (SQLite: accounts, friends, rooms, plugin subscriptions, admin password hash) + `avatars/` + `jwt-secret` (the signing key generated by the server) |
| Backup | Just archive the volume (example, any base image works): `docker run --rm -v omioclink_server-data:/data -v "$PWD":/backup alpine tar czf /backup/omioclink-data.tgz -C /data .` |
| Restore | The reverse: `docker run --rm -v omioclink_server-data:/data -v "$PWD":/backup alpine tar xzf /backup/omioclink-data.tgz -C /data` |
| Upgrade | `docker compose pull && docker compose up -d` (in an offline environment, re-import the tar as described in option 2) |
| Rollback | Set `OMIOCLINK_IMAGE=omioc/omioclink:v<old version>` in `.env` → `docker compose up -d` |

Avatars and SQLite live in the same volume, so a single backup captures everything; `down -v` deletes the volume, so do not run it without a backup

---

## 11. FAQ

| Symptom | Cause / fix |
| --- | --- |
| `docker compose up` reports "please set OMIOCLINK_JWT_SECRET in .env" | That is an old version (1.0.5 and earlier). Current versions just leave it empty: the server generates the key itself and stores it in `jwt-secret` in the data volume |
| Opening `/admin` asks for a password | Expected: the admin console needs an admin password on first use (it used to be a token); once set you can log in |
| The admin console password is forgotten | Delete the `admin_account` row in the database and set it again (the command is in section 7) |
| Does the `OMIOCLINK_ADMIN_TOKEN` in an old `.env` still work? | It works as a transitional token until you "set the admin password"; after that it is invalid, so you can delete that line |
| `/docs` returns 404 | `OMIOCLINK_DOCS_ENABLED=false` (the default); set it to `true` temporarily while debugging |
| `docker ps` shows `unhealthy` | Usually database or data directory permissions, or a JWT key that does not meet the requirements; check `docker compose logs server` first |
| Clients cannot connect although the container is healthy | Allow TCP `21077`; with a domain plus reverse proxy, make sure `OMIOCLINK_BIND_ADDR` matches where the reverse proxy points; when using plain `http/ws`, the client must allow cleartext |
| It connects but voice hole punching fails | That is the price of the "no relay" architecture and has nothing to do with the server: symmetric NAT and networks that block UDP will fail; first enable self-hosted STUN (section 6), then follow the client's hint and switch networks |
| Changes to `.env` have no effect | Environment variables are read at container startup, so run `docker compose up -d` to recreate it after a change |
| Want to change the listening port | `ports` is defined in `deploy/docker-compose.yml` and `server/docker-compose.yml` (change both sides); clients use `<host>:<port>` |
