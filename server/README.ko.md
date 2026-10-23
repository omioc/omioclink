# OmiocLink 서버

<p><b>语言 / Languages:</b> <a href="README.md">中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

FastAPI 시그널링 서버 + STUN + 웹 관리 콘솔

**시그널링과 상태만 처리하며 미디어는 절대 중계하지 않습니다**: 음성, 화면 공유, 채팅은 모두 멤버 간 직접 연결(WebRTC + DTLS-SRTP)로 이루어지고, 서버에는 TURN도 릴레이 프로세스도 없으므로 트래픽은 항상 KB 수준입니다

- 외부에 노출되는 것은 `21077`(HTTP + WebSocket)과 선택 사항인 `3478/udp`(자체 STUN)뿐입니다
- 데이터 볼륨은 하나뿐입니다: `omioclink_server-data` → `/app/data`(SQLite + 아바타 + 플러그인 구독). 백업은 이 볼륨을 가져가면 끝입니다
- 두 배포 방식 모두 프로젝트 이름이 `omioclink`이고 데이터 볼륨 이름도 같아서, **서로 전환할 수 있으며 데이터를 옮길 필요가 없습니다**

---

## 1. 온라인 배포

전제 조건: 공인 IPv4가 있는 Linux에 Docker와 compose 플러그인이 설치되어 있고 GitHub와 Docker Hub에 연결할 수 있어야 합니다:

```bash
curl -fsSL https://raw.githubusercontent.com/omioc/omioclink/main/deploy/install.sh -o /tmp/omioc-install.sh && sudo bash /tmp/omioc-install.sh
```

- 기본 설치 경로는 `/opt/omioc_server`이며 `--dir`로 변경할 수 있습니다. 전체 로그는 `<설치 경로>/deploy-<날짜>.log`에 남습니다
- 멱등: 중단되거나 인자를 바꾼 뒤에도 같은 명령을 다시 실행하면 됩니다. 이미 완료된 단계는 자동으로 건너뜁니다(`.env`를 덮어쓰지 않고 키도 다시 만들지 않습니다)

---

## 2. 오프라인 배포

### 방법 1: 프로젝트에서 tar 패키지를 내려받아 오프라인 배포

이미지 패키지 다운로드:

[x86 아키텍처](https://github.com/omioc/omioclink/releases/latest/download/omioclink-server-1.0.7-amd64.tar) | 
[arm 아키텍처](https://github.com/omioc/omioclink/releases/latest/download/omioclink-server-1.0.7-arm64.tar)

```bash
# 1. 이미지 패키지를 서버에 업로드하고 docker load -i <image-name>.tar 로 이미지를 가져옵니다
# 2. 프로젝트 루트의 deploy 폴더를 서버로 복사합니다
cd deploy
cp .env.example .env
# 선택: OMIOCLINK_JWT_SECRET 을 비워 두면 서버가 자동으로 생성해 영구 저장합니다. 관리자 비밀번호는 관리 콘솔을 처음 열 때 설정합니다
# STUN 을 켜는 경우 실제 환경에 맞게 OMIOCLINK_ICE_SERVERS 값을 채웁니다 — stun:<공인 IP / 도메인>:3478
docker compose --profile stun up -d
docker ps
```

### 방법 2: 이미지를 직접 빌드해 오프라인 배포

```bash
git clone https://github.com/omioc/omioclink.git
cd omioclink/server

docker build -t omioc/omioclink:latest .

# 2. tar 내보내기: 버전은 pyproject.toml 에서 가져오고 아키텍처는 빌드 머신과 같습니다
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
docker save omioc/omioclink:latest -o "omioclink-server-${VERSION}-${ARCH}.tar"
```

산출물은 현재 디렉터리의 `omioclink-server-<버전>-<아키텍처>.tar`이며, 이후 단계는 방법 1과 같습니다

빌드 시 의존성 소스는 기본적으로 칭화대 미러를 사용합니다. 공식 소스를 쓰려면 build 줄을 `docker build --build-arg PIP_INDEX_URL=https://pypi.org/simple -t omioc/omioclink:latest .` 로 바꾸면 됩니다

---

## 3. 환경 변수

모든 변수는 `OMIOCLINK_` 접두사를 가지며 `.env`에 작성하거나 직접 `export`할 수 있습니다

전체 목록과 기본값은 [`app/core/config.py`](app/core/config.py)를 참고하세요. 아래 표는 배포 시 조정하는 항목입니다:

| 변수 | 기본값 | 설명 |
| --- | --- | --- |
| `OMIOCLINK_JWT_SECRET` | 비어 있음(자동 생성) | HS256 서명 키. **비워 두면 자동으로 생성**되어 데이터 볼륨의 `jwt-secret` 파일에 영구 저장됩니다. 직접 지정할 때는 최소 32바이트여야 합니다 |
| `OMIOCLINK_ADMIN_TOKEN` | 비어 있음 | **폐기 예정**: 관리 콘솔은 관리자 비밀번호 로그인으로 바뀌었습니다. 이 값은 관리자 비밀번호를 아직 설정하지 않았을 때의 과도기 토큰으로만 쓸 수 있습니다 |
| `OMIOCLINK_ADMIN_SESSION_TTL_SECONDS` | `43200`(12시간) | 관리 콘솔 로그인 상태의 유효 기간. 비밀번호를 바꾸면 기존 로그인 상태는 모두 즉시 무효가 됩니다 |
| `OMIOCLINK_ALLOW_REGISTRATION` | `false` | 자가 등록 허용 여부. 관리 콘솔에서 일시적으로 전환할 수도 있습니다(재시작하면 여기 값으로 돌아갑니다) |
| `OMIOCLINK_DOCS_ENABLED` | `false` | `/docs`와 `/openapi.json`을 노출할지 여부(API 전체를 외부에 공개하게 됩니다) |
| `OMIOCLINK_ICE_SERVERS` | `stun:stun.cloudflare.com:3478` | 클라이언트에 내려보내는 STUN 목록. 쉼표로 구분하거나 JSON 배열로 지정합니다. **`stun:` 만 넣으세요. 이 프로젝트는 TURN을 지원하지 않습니다** |
| `OMIOCLINK_BIND_ADDR` | `0.0.0.0` | compose의 포트 바인딩 주소에만 영향을 줍니다. TLS 리버스 프록시 뒤에 둘 때는 `127.0.0.1`로 좁히세요 |
| `OMIOCLINK_CORS_ORIGINS` | `*` | 허용할 교차 출처(CORS). 클라이언트는 데스크톱/모바일 앱이라 브라우저 동일 출처 정책을 거치지 않으므로 필요에 따라 좁히세요 |
| `OMIOCLINK_MUSIC_ENABLED` | `true` | 신청곡 기능의 전체 스위치(끄면 클라이언트에 진입점이 표시되지 않습니다) |
| `OMIOCLINK_AVATAR_MAX_BYTES` | `2097152` | 아바타 한 장의 바이트 상한(클라이언트가 먼저 256px로 줄이므로 보통 수십 KB입니다) |
| `OMIOCLINK_DATABASE_URL` | compose에서 `sqlite+aiosqlite:////app/data/omioclink.db`로 고정 | 데이터베이스 파일은 데이터 볼륨에 저장됩니다 |
| `OMIOCLINK_DATA_DIR` | compose에서 `/app/data`로 고정 | 아바타 등 파일이 저장되는 위치(`<data_dir>/avatars/`) |
| `OMIOCLINK_IMAGE` | `omioc/omioclink:latest` | compose 전용: 버전을 고정하거나 롤백할 때 태그가 붙은 이미지로 바꿉니다 |
| `OMIOCLINK_PIP_INDEX_URL` | 칭화대 PyPI 미러 | `server/docker-compose.yml`의 `--build`에만 유효: 빌드 시 의존성을 설치하는 소스 |

하트비트와 방 정원의 기본값(`OMIOCLINK_HEARTBEAT_INTERVAL_SECONDS=30`, `..._TIMEOUT_SECONDS=90`,
`OMIOCLINK_DEFAULT_ROOM_CAPACITY=5`, `OMIOCLINK_MAX_ROOM_CAPACITY=8`)은 보통 바꿀 필요가 없습니다

---

## 4. 디렉터리 구조

| 경로 | 내용 |
| --- | --- |
| `app/` | FastAPI 애플리케이션: `api/`(REST), `signaling/`(WebSocket 프로토콜, 방과 멤버 상태), `stun/`(주소 되돌려주기), `db/`, `services/` |
| `tests/` | pytest 테스트(`uv run pytest`) |
| `Dockerfile` | 단일 단계 슬림 이미지. 비root(`omioclink:omioclink`)로 실행하며 헬스 체크가 내장되어 있습니다 |
| `docker-compose.yml` | **오프라인 배포**: 이 디렉터리의 `Dockerfile`로 `omioc/omioclink:latest`를 로컬 빌드한 뒤 tar로 내보내 서버에 업로드해 배포합니다 |
| `tool/export_image.ps1` | 이미지를 오프라인용 tar로 내보냅니다(`releases/server-v<버전>/`). 버전은 `pyproject.toml`에서 가져옵니다 |
| `../deploy/` | **온라인 배포**: Docker Hub의 `omioc/omioclink:latest`만 받아오며 빌드가 필요 없습니다 |

---

## 5. 외부 인터페이스

| 경로 | 설명 |
| --- | --- |
| `GET /api/v1/health` | 헬스 체크. Dockerfile의 `HEALTHCHECK`도 이 엔드포인트를 호출하며, `docker ps`의 healthy 여부는 이것으로 결정됩니다 |
| `GET /api/v1/server/info` | 서버 기능과 내려주는 설정(이름, 버전, 등록 스위치, 방 정원, ICE/STUN 목록) |
| `WS /ws` | 시그널링: 입장/퇴장, 멤버 상태, `offer`/`answer`/`candidate` 전달, 애플리케이션 계층 하트비트와 시각 동기화 |
| `GET /admin` | 웹 관리 콘솔. **항상 사용 가능**: 처음 열 때 관리자 비밀번호 설정을 요구합니다 |
| `GET /api/v1/admin/*` | 관리 API(`Authorization: Bearer` + 관리자 비밀번호로 교환한 토큰). 구버전 배포의 `X-Admin-Token`은 비밀번호를 설정하기 전까지만 사용할 수 있습니다 |
| `GET /docs`, `/openapi.json` | Swagger UI와 OpenAPI 문서. **`OMIOCLINK_DOCS_ENABLED=true`일 때만 등록**되며, 켜는 것을 권장하지 않습니다 |

포트:

| 포트 | 용도 | 노출 방식 |
| --- | --- | --- |
| `21077/tcp` | 주 서비스(REST + WebSocket) | compose 포트 매핑. 리버스 프록시에만 열어 주도록 좁힐 수 있습니다 |
| `3478/udp` | 선택 사항인 자체 STUN | `--profile stun`을 켰을 때만 시작하며 `network_mode: host`가 필수입니다 |

---

## 6. 자체 STUN(선택, 권장)

공용 STUN(`stun.l.google.com` 등)은 중국 내 도달성이 불안정하므로 직접 구축하는 것이 가장 안정적입니다:

```bash
cd deploy
docker compose --profile stun up -d
```

그다음 `.env`의 `OMIOCLINK_ICE_SERVERS`가 이 주소를 가리키도록 설정합니다. 예:

```
OMIOCLINK_ICE_SERVERS=stun:<공인 IP / 도메인>:3478
```

변경 후에는 `docker compose up -d`로 컨테이너를 한 번 다시 만들어야 합니다(환경 변수는 시작할 때 읽힙니다)

**`network_mode: host`가 필수입니다**: STUN은 "클라이언트가 본 송신 주소"를 그대로 되돌려줘야 합니다

이것은 "내 공인 매핑 주소가 무엇인가"에 답할 뿐이며, 시그널링과 함께 연결 탐색에 속합니다. **어떤 미디어도 중계하지 않습니다** — 릴레이가 아니고 TURN을 대신하지도 않습니다

---

## 7. 웹 관리 콘솔

1. `docker compose up -d`(**키를 설정할 필요가 전혀 없습니다**), 브라우저에서 `http://<서버 IP / 도메인>:21077/admin` 열기
2. 처음 열면 "관리자 비밀번호 설정"이 뜨고, 설정하면 자동으로 로그인됩니다. 비밀번호는 bcrypt 해시로만 저장됩니다(`admin_account` 테이블)
3. 이후에는 비밀번호로 로그인합니다. 오른쪽 위에서 비밀번호를 바꾸거나(바꾸면 다른 브라우저의 로그인 상태가 즉시 무효가 됩니다) 로그아웃할 수 있습니다

네 개의 섹션:

- **사용자 자가 등록**: 임시 스위치(DB에 기록하지 않으며 재시작하면 `.env` 값으로 돌아갑니다)
- **방**: 온라인 방 목록, 정원, 현재 멤버. 멤버를 내보내거나 방을 해산할 수 있습니다
- **계정**: 사용자 이름/닉네임으로 검색, 생성, 비활성화/활성화, 삭제
- **음악 플러그인 구독**: 클라이언트에 내려줄 플러그인 구독 주소(`.json` 매니페스트 또는 `.js` 직링크)를 관리합니다. 클라이언트는 서버에 연결되면 자동으로 동기화하고
  `sha256`으로 재설치가 필요한지 판단합니다

> 비밀번호를 잊었다면: DB에서 해당 행을 지우고 다시 설정하세요 —
> `docker compose exec server python -c "import sqlite3; c=sqlite3.connect('/app/data/omioclink.db'); c.execute('DELETE FROM admin_account'); c.commit()"`

> **구버전에서 업그레이드**(`.env`에 `OMIOCLINK_ADMIN_TOKEN`이 남아 있는 경우): 이때도 페이지가 "관리자 비밀번호 설정"을 띄웁니다.
> 설정하기 전까지는 기존 토큰(`X-Admin-Token`)을 과도기 스크립트용으로 쓸 수 있고, 설정하면 즉시 무효가 됩니다. 그 뒤 `.env`에서 해당 줄을 삭제하세요.

> 관리 콘솔은 외부에 공개됩니다. 첫 배포 후 **가능한 한 빨리** 관리자 비밀번호를 설정하고, "비밀번호 설정" 화면을 공인 인터넷에 방치하지 마세요.
> 내부망에서만 쓰려면 `21077`을 리버스 프록시 뒤에 두거나 `OMIOCLINK_BIND_ADDR=127.0.0.1`을 설정하세요.

> "비밀번호 설정 / 로그인" 두 엔드포인트는 **동일 출처** 페이지에서 온 요청만 받습니다(`Sec-Fetch-Site`와 `Origin`/`Host` 이중 판정).
> 다른 사이트가 방문자의 브라우저를 빌려 관리자 비밀번호를 설정하는 것을 막기 위해서입니다. 리버스 프록시는 브라우저 요청을 교차 사이트로 바꾸지만 않으면
> 그대로 사용할 수 있습니다(최신 브라우저는 모두 `Sec-Fetch-Site`를 보내며 Host 재작성에 영향을 받지 않습니다).

> **로그인 시도 제한**(온라인 비밀번호 추측 방지): 관리 콘솔은 같은 IP에서 5회 연속 실패하면 5분 동안 잠깁니다(잠금 중에는 올바른 비밀번호도 통과하지 못합니다).
> 클라이언트 계정은 연속으로 틀리면 지수 백오프(처음 3회는 일반 오류, 이후 2s → 4s → … 최대 60s)를 적용합니다.
> 같은 IP는 5분에 최대 10회의 로그인 요청만 보낼 수 있습니다. 카운터는 프로세스 메모리에 있어 재시작하면 초기화됩니다(단일 컨테이너 배포에는 충분합니다).
>
> **로그인 기록**: 모든 시도(클라이언트 / 관리 콘솔, 성공 / 실패)가 사용자 이름, 송신 IP,
> User-Agent, 성공 여부와 함께 기록되며 30일간 보관됩니다(`login_records` 테이블). 관리 화면은 아직 이 부분을 지원하지 않으므로 당분간 API로 확인하세요:
>
> ```bash
> curl -H "Authorization: Bearer <관리 콘솔 토큰>" \
>   "http://127.0.0.1:21077/api/v1/admin/logins?onlyFailed=true&limit=20"
> ```
>
> 리버스 프록시 뒤에 배포할 때 송신 IP는 `X-Forwarded-For`의 첫 번째 값입니다. 다만 이 헤더를 신뢰하는 것은
> **직접 연결한 상대가 사설망이거나 루프백일 때만**입니다. 공인망에서 직접 연결해 위조해도 제한을 우회할 수 없습니다.

> 계정을 한꺼번에 만들려면: `.env`에서 `OMIOCLINK_ALLOW_REGISTRATION=true` → `docker compose up -d` → 클라이언트에서 자가 등록 → 다시 `false`로 바꾸고 `up -d`; 또는 관리자가 콘솔에서 계정을 만들고 등록 스위치는 꺼 두면 됩니다

---

## 8. 디버깅

### 로컬에서 서비스를 띄우고 코드 변경을 즉시 반영

```bash
cd server
uv sync
uv run uvicorn app.main:app --host 0.0.0.0 --port 21077 --reload
```

- `--reload`를 붙이면 한 줄을 저장할 때마다 자동으로 재시작하며, 클라이언트는 로컬 `127.0.0.1:21077`에 그대로 연결할 수 있습니다
- API 문서를 보려면: `OMIOCLINK_DOCS_ENABLED=true uv run uvicorn app.main:app --port 21077 --reload`,
  그다음 `http://127.0.0.1:21077/docs`를 엽니다
- 스모크 테스트: `curl http://127.0.0.1:21077/api/v1/health`, `curl http://127.0.0.1:21077/api/v1/server/info`
- 로컬 관리 콘솔: `http://127.0.0.1:21077/admin`을 바로 엽니다. 처음에는 관리자 비밀번호 설정을 요구합니다(비밀번호는 `./omioclink.db`에 저장됩니다)

> 로컬에서 실행할 때 데이터베이스는 `./omioclink.db`, 데이터 디렉터리는 `./data`입니다(`config.py` 기본값). 컨테이너의 `/app/data`와는 서로 영향을 주지 않습니다

### 운영 중인 컨테이너 점검

```bash
docker compose ps                     # healthy 인지 unhealthy 인지
docker compose logs -f server         # 로그 따라 보기(uvicorn 액세스 로그 + 처리되지 않은 예외 스택)
docker compose exec server python -c "import app; print(app.__version__)"   # 컨테이너에 실제로 들어 있는 버전
docker compose exec server ls -l /app/data                                  # 데이터 볼륨이 마운트되었는지
```

- 이벤트 루프가 멈춘 것 같으면 `OMIOCLINK_DEBUG_TASKS=1`로 컨테이너를 시작하세요. 0.5초마다 이벤트 루프의 모든 작업을
  파일명:행번호:함수 형태로 표준 출력에 덤프합니다("API가 응답하지 않고 로그도 조용한" 유형의 멈춤을 진단하는 가장 직접적인 방법입니다)
- 컨테이너는 비root 사용자 `omioclink`로 실행되며 `exec`로 들어가도 같은 사용자입니다. 파일 수정이나 패키지 설치는 Dockerfile을 바꾸세요

---

## 9. 테스트와 정적 검사

```bash
cd server
uv run pytest                # 테스트(케이스당 20s 타임아웃, 멈추면 실패와 스택으로 드러납니다)
uv run ruff check .          # 정적 검사(줄 너비 100, 규칙은 pyproject)
uv run mypy                  # 타입 검사(strict)
```

세 가지 모두 깨끗해야 합니다. CI는 push와 PR마다 같은 세 가지에 더해 버전 번호 드리프트 검사를 실행합니다

---

## 10. 데이터, 백업, 업그레이드

| 항목 | 값 |
| --- | --- |
| 데이터 볼륨 | `omioclink_server-data` → `/app/data` |
| 포함 내용 | `omioclink.db`(SQLite: 계정, 친구, 방, 플러그인 구독, 관리자 비밀번호 해시) + `avatars/` + `jwt-secret`(서버가 자동 생성한 서명 키) |
| 백업 | 볼륨을 압축해 두면 됩니다(예시, 베이스 이미지는 아무거나 가능): `docker run --rm -v omioclink_server-data:/data -v "$PWD":/backup alpine tar czf /backup/omioclink-data.tgz -C /data .` |
| 복원 | 반대로 하면 됩니다: `docker run --rm -v omioclink_server-data:/data -v "$PWD":/backup alpine tar xzf /backup/omioclink-data.tgz -C /data` |
| 업그레이드 | `docker compose pull && docker compose up -d`(오프라인 환경에서는 방법 2로 tar를 다시 가져오기) |
| 롤백 | `.env`에서 `OMIOCLINK_IMAGE=omioc/omioclink:v<이전 버전>` → `docker compose up -d` |

아바타와 SQLite가 같은 볼륨에 있으므로 백업 한 번이면 전체입니다. `down -v`는 볼륨을 삭제하니 백업 없이 실행하지 마세요

---

## 11. 자주 묻는 질문

| 증상 | 원인 / 대응 |
| --- | --- |
| `docker compose up`이 ".env에 OMIOCLINK_JWT_SECRET을 설정하세요"라고 표시 | 그것은 구버전(1.0.5 이하)입니다. 최신 버전은 비워 두면 됩니다. 서버가 키를 자동 생성해 데이터 볼륨의 `jwt-secret`에 저장합니다 |
| `/admin`을 열면 비밀번호 설정을 요구 | 정상입니다. 관리 콘솔은 처음 사용할 때 관리자 비밀번호를 설정해야 합니다(예전에는 토큰을 입력했습니다). 설정하면 로그인할 수 있습니다 |
| 관리 콘솔 비밀번호를 잊었다 | DB의 `admin_account` 행을 지우고 다시 설정하세요(7장에 명령이 있습니다) |
| 구 `.env`의 `OMIOCLINK_ADMIN_TOKEN`을 아직 쓸 수 있나? | "관리자 비밀번호 설정" 전까지는 과도기 토큰으로 쓸 수 있습니다. 설정하면 무효가 되므로 그 줄을 삭제하세요 |
| `/docs`를 열면 404 | `OMIOCLINK_DOCS_ENABLED=false`(기본값)입니다. 디버깅할 때만 일시적으로 `true`로 두세요 |
| `docker ps`에 `unhealthy`로 표시 | 대부분 데이터베이스/데이터 디렉터리 권한이나 JWT 키가 요구 사항을 충족하지 못한 경우입니다. 먼저 `docker compose logs server`를 확인하세요 |
| 클라이언트는 연결되지 않는데 컨테이너는 healthy | TCP `21077`을 허용하세요. 도메인 + 리버스 프록시를 쓸 때는 `OMIOCLINK_BIND_ADDR`과 리버스 프록시가 가리키는 대상이 일치하는지 확인하세요. `http/ws` 평문을 쓰려면 클라이언트에서 평문을 허용해야 합니다 |
| 연결은 되지만 음성 홀 펀칭이 실패 | "릴레이 없음" 아키텍처의 대가이며 서버와는 무관합니다. 대칭형 NAT나 UDP를 막는 네트워크에서는 실패합니다. 먼저 자체 STUN을 켜고(6장) 클라이언트 안내에 따라 네트워크를 바꾸세요 |
| `.env`를 바꿔도 반영되지 않음 | 환경 변수는 컨테이너 시작 시 읽힙니다. 변경 후 `docker compose up -d`로 다시 만들어야 합니다 |
| 수신 포트를 바꾸고 싶다 | `ports`는 `deploy/docker-compose.yml`과 `server/docker-compose.yml`에 있습니다(양쪽을 함께 수정). 클라이언트에는 `<host>:<port>`를 입력합니다 |
