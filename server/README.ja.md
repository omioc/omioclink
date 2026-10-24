# OmiocLink サーバー

<p><b>语言 / Languages:</b> <a href="README.md">中文</a> · <a href="README.en.md">English</a> · <a href="README.ja.md">日本語</a> · <a href="README.ko.md">한국어</a></p>

FastAPI シグナリングサーバー + STUN + Web 管理コンソール

**シグナリングと状態管理のみを行い、メディアは一切中継しません**：音声・画面共有・チャットはすべてメンバー間の直接接続（WebRTC + DTLS-SRTP）で行われ、サーバーには TURN もリレープロセスもありません。通信量は常に KB 単位です

- 外部に公開するのは `21077`（HTTP + WebSocket）と、任意の `3478/udp`（自前 STUN）のみ
- データ用ボリュームは 1 つだけ：`omioclink_server-data` → `/app/data`（SQLite + アバター + プラグイン購読）。バックアップはこのボリュームを取得するだけで完了
- どちらのデプロイ方法もプロジェクト名は `omioclink`、データボリューム名も同じなので、**相互に切り替えられ、データを移す必要はありません**

---

## 1. オンラインデプロイ

前提：パブリック IPv4 を持つ Linux に Docker と compose プラグインが導入済みで、GitHub と Docker Hub に接続できること：

```bash
curl -fsSL https://raw.githubusercontent.com/omioc/omioclink/main/deploy/install.sh -o /tmp/omioc-install.sh && sudo bash /tmp/omioc-install.sh
```

- 既定のインストール先は `/opt/omioc_server`（`--dir` で変更可）。ログはすべて `<インストール先>/deploy-<日付>.log` に残ります
- 冪等：途中で中断したり引数を変えたりしても、同じコマンドを再実行すれば OK です。完了済みの手順は自動的にスキップされます（`.env` は上書きせず、鍵も再生成しません）

---

## 2. オフラインデプロイ

### 方法 1：プロジェクトから tar パッケージをダウンロードしてオフラインデプロイ

イメージパッケージをダウンロード：

[x86 アーキテクチャ](https://github.com/omioc/omioclink/releases/latest/download/omioclink-server-1.0.8-amd64.tar) | 
[arm アーキテクチャ](https://github.com/omioc/omioclink/releases/latest/download/omioclink-server-1.0.8-arm64.tar)

```bash
# 1. イメージパッケージをサーバーにアップロードし、docker load -i <image-name>.tar でインポートします
# 2. プロジェクト直下の deploy フォルダーをサーバーにコピーします
cd deploy
cp .env.example .env
# 任意：OMIOCLINK_JWT_SECRET を空にしておくと、サーバーが自動生成して永続化します。管理者パスワードは管理コンソールを初めて開いたときに設定します
# STUN を有効にする場合は、実際の環境に合わせて OMIOCLINK_ICE_SERVERS に値を設定します —— stun:<パブリック IP / ドメイン>:3478
docker compose --profile stun up -d
docker ps
```

### 方法 2：イメージを自分でビルドしてオフラインデプロイ

```bash
git clone https://github.com/omioc/omioclink.git
cd omioclink/server

docker build -t omioc/omioclink:latest .

# 2. tar をエクスポート：バージョンは pyproject.toml から取得し、アーキテクチャはビルドマシンと同じになります
VERSION=$(sed -n 's/^version = "\(.*\)"/\1/p' pyproject.toml)
ARCH=$(uname -m | sed 's/x86_64/amd64/; s/aarch64/arm64/')
docker save omioc/omioclink:latest -o "omioclink-server-${VERSION}-${ARCH}.tar"
```

生成物はカレントディレクトリの `omioclink-server-<バージョン>-<アーキテクチャ>.tar` で、以降の手順は方法 1 と同じです

ビルド時の依存取得は既定で清華大学のミラーを使用します。公式ソースを使う場合は build の行を `docker build --build-arg PIP_INDEX_URL=https://pypi.org/simple -t omioc/omioclink:latest .` に置き換えてください

---

## 3. 環境変数

すべての変数は接頭辞 `OMIOCLINK_` を持ち、`.env` に書くか直接 `export` できます

完全な一覧と既定値は [`app/core/config.py`](app/core/config.py) を参照してください。次の表はデプロイ時に変更するものです：

| 変数 | 既定値 | 説明 |
| --- | --- | --- |
| `OMIOCLINK_JWT_SECRET` | 空（自動生成） | HS256 の署名鍵。**空にしておけば自動生成**され、データボリュームの `jwt-secret` ファイルに永続化されます。指定する場合は 32 バイト以上にしてください |
| `OMIOCLINK_ADMIN_TOKEN` | 空 | **非推奨**：管理コンソールは管理者パスワードでのログインに変わりました。この値は管理者パスワードをまだ設定していない間の暫定トークンとしてのみ使えます |
| `OMIOCLINK_ADMIN_SESSION_TTL_SECONDS` | `43200`（12 時間） | 管理コンソールのログイン状態の有効期間。パスワードを変更すると既存のログイン状態はすべて即座に無効になります |
| `OMIOCLINK_ALLOW_REGISTRATION` | `false` | 自己登録を許可するかどうか。管理コンソールから一時的に切り替えることもできます（再起動するとここの値に戻ります） |
| `OMIOCLINK_DOCS_ENABLED` | `false` | `/docs` と `/openapi.json` を公開するかどうか（API 全体を外部に公開することになります） |
| `OMIOCLINK_ICE_SERVERS` | `stun:stun.cloudflare.com:3478` | クライアントに配信する STUN のリスト。カンマ区切りまたは JSON 配列。**`stun:` のみを指定してください。本プロジェクトは TURN に対応していません** |
| `OMIOCLINK_BIND_ADDR` | `0.0.0.0` | compose のポートバインドアドレスにのみ影響します。TLS リバースプロキシの背後に置く場合は `127.0.0.1` に絞ってください |
| `OMIOCLINK_CORS_ORIGINS` | `*` | 許可するクロスオリジン（クライアントはデスクトップ/モバイルアプリで、ブラウザーの同一オリジンポリシーは適用されません。必要に応じて絞ってください） |
| `OMIOCLINK_MUSIC_ENABLED` | `true` | 選曲機能のマスタースイッチ（オフにするとクライアント側に入口が表示されません） |
| `OMIOCLINK_AVATAR_MAX_BYTES` | `2097152` | アバター 1 枚あたりのバイト上限（クライアントが先に 256px へ縮小するため、通常は数十 KB 程度です） |
| `OMIOCLINK_DATABASE_URL` | compose で `sqlite+aiosqlite:////app/data/omioclink.db` に固定 | データベースファイルはデータボリューム内に置かれます |
| `OMIOCLINK_DATA_DIR` | compose で `/app/data` に固定 | アバターなどのファイルの保存先（`<data_dir>/avatars/`） |
| `OMIOCLINK_IMAGE` | `omioc/omioclink:latest` | compose 専用：バージョンを固定したりロールバックしたりするときはタグ付きイメージに変更します |
| `OMIOCLINK_PIP_INDEX_URL` | 清華大学の PyPI ミラー | `server/docker-compose.yml` の `--build` にのみ有効：ビルド時に依存を取得するソース |

ハートビートとルーム定員の既定値（`OMIOCLINK_HEARTBEAT_INTERVAL_SECONDS=30`、`..._TIMEOUT_SECONDS=90`、
`OMIOCLINK_DEFAULT_ROOM_CAPACITY=5`、`OMIOCLINK_MAX_ROOM_CAPACITY=8`）は通常変更不要です

---

## 4. ディレクトリ構成

| パス | 内容 |
| --- | --- |
| `app/` | FastAPI アプリケーション：`api/`（REST）、`signaling/`（WebSocket プロトコル、ルームとメンバーの状態）、`stun/`（アドレス返却）、`db/`、`services/` |
| `tests/` | pytest のテストケース（`uv run pytest`） |
| `Dockerfile` | シングルステージのスリムイメージ。非 root（`omioclink:omioclink`）で実行し、ヘルスチェックを内蔵 |
| `docker-compose.yml` | **オフラインデプロイ**：このディレクトリの `Dockerfile` から `omioc/omioclink:latest` をローカルビルドし、tar に書き出してサーバーへアップロードしてデプロイします |
| `tool/export_image.ps1` | イメージをオフライン用 tar に書き出します（`releases/server-v<バージョン>/`）。バージョンは `pyproject.toml` から取得 |
| `../deploy/` | **オンラインデプロイ**：Docker Hub 上の `omioc/omioclink:latest` を取得するだけで、ビルドは不要 |

---

## 5. 公開インターフェース

| パス | 説明 |
| --- | --- |
| `GET /api/v1/health` | ヘルスチェック。Dockerfile の `HEALTHCHECK` もこれを叩いており、`docker ps` の healthy はこれで決まります |
| `GET /api/v1/server/info` | サーバーの機能と配信設定（名前、バージョン、登録スイッチ、ルーム定員、ICE/STUN リスト） |
| `WS /ws` | シグナリング：入室/退室、メンバー状態、`offer`/`answer`/`candidate` の転送、アプリケーション層のハートビートと時刻同期 |
| `GET /admin` | Web 管理コンソール。**常に利用可能**：初回アクセス時に管理者パスワードの設定を求められます |
| `GET /api/v1/admin/*` | 管理用 API（`Authorization: Bearer` + 管理者パスワードと引き換えたトークン）。旧デプロイの `X-Admin-Token` はパスワード設定前のみ使えます |
| `GET /docs`、`/openapi.json` | Swagger UI と OpenAPI 記述。**`OMIOCLINK_DOCS_ENABLED=true` のときだけ登録**されます。有効化は推奨しません |

ポート：

| ポート | 用途 | 公開方法 |
| --- | --- | --- |
| `21077/tcp` | メインサービス（REST + WebSocket） | compose のポートマッピング。リバースプロキシのみに絞ることも可能 |
| `3478/udp` | 任意の自前 STUN | `--profile stun` を指定したときだけ起動し、`network_mode: host` が必須 |

---

## 6. 自前 STUN（任意、推奨）

公共 STUN（`stun.l.google.com` など）は中国国内での到達性が不安定なため、自前で用意するのが最も安定します：

```bash
cd deploy
docker compose --profile stun up -d
```

次に `.env` の `OMIOCLINK_ICE_SERVERS` をそれを指すように設定します。例えば：

```
OMIOCLINK_ICE_SERVERS=stun:<パブリック IP / ドメイン>:3478
```

変更後は `docker compose up -d` でコンテナを一度作り直してください（環境変数は起動時に読み込まれます）

**`network_mode: host` が必須**：STUN は「クライアントから見えた送信元アドレス」をそのまま返す必要があります

これは「自分のパブリック側のマッピングアドレスは何か」に答えるだけで、シグナリングと同じく「接続先の探索」に属します。**メディアは一切中継しません** —— リレーではなく、TURN の代わりにもなりません

---

## 7. Web 管理コンソール

1. `docker compose up -d`（**鍵の設定は一切不要**）、ブラウザーで `http://<サーバー IP / ドメイン>:21077/admin` を開きます
2. 初回は「管理者パスワードの設定」が表示され、設定すると自動的にログインします。パスワードは bcrypt ハッシュのみ保存されます（`admin_account` テーブル）
3. 以降はパスワードログインです。右上からパスワードの変更（変更すると他のブラウザーのログイン状態は即座に無効になります）やログアウトができます

4 つのセクション：

- **ユーザーの自己登録**：一時的なオン/オフ（データベースには書き込まれず、再起動すると `.env` の値に戻ります）
- **ルーム**：オンラインルームの一覧、定員、現在のメンバー。メンバーの追い出しやルームの解散ができます
- **アカウント**：ユーザー名/ニックネームで検索、作成、無効化/有効化、削除
- **音楽プラグイン購読**：クライアントに配信するプラグイン購読 URL（`.json` マニフェストまたは `.js` 直リンク）を管理します。クライアントはサーバーに接続すると自動的に同期し、
  `sha256` で再インストールが必要かどうかを判断します

> パスワードを忘れた場合：データベースの該当行を削除して再設定します ——
> `docker compose exec server python -c "import sqlite3; c=sqlite3.connect('/app/data/omioclink.db'); c.execute('DELETE FROM admin_account'); c.commit()"`

> **旧バージョンからのアップグレード**（`.env` に `OMIOCLINK_ADMIN_TOKEN` が残っている場合）：同じく「管理者パスワードの設定」が表示されます。
> 設定するまでは旧トークン（`X-Admin-Token`）が使えます（移行期間のスクリプト用に便利です）。設定すると即座に無効になるので、その後 `.env` の該当行を削除してください。

> 管理コンソールは外部に公開されます。初回デプロイ後は**できるだけ早く**管理者パスワードを設定し、「パスワード設定」画面を公開されたインターネット上に放置しないでください。
> 社内ネットワークからのみ使いたい場合は、`21077` をリバースプロキシの背後に置くか、`OMIOCLINK_BIND_ADDR=127.0.0.1` を設定してください。

> 「パスワード設定 / ログイン」の 2 つのエンドポイントは、**同一オリジン**のページからのリクエストのみ受け付けます（`Sec-Fetch-Site` と `Origin`/`Host` の二重判定）。
> 他のサイトが訪問者のブラウザーを借りて管理者パスワードを設定してしまうのを防ぐためです。リバースプロキシは、ブラウザーのリクエストをクロスサイトに変換しない限り
> そのまま使えます（現代のブラウザーは `Sec-Fetch-Site` を送信し、Host の書き換えにも影響されません）。

> **ログイン試行の制限**（オンラインでのパスワード総当たり対策）：管理コンソールは同一 IP で 5 回連続失敗すると 5 分間ロックされます（ロック中は正しいパスワードも通りません）。
> クライアントのアカウントは連続失敗で指数バックオフ（最初の 3 回は通常のエラー、その後 2s → 4s → … 最大 60s）。
> 同一 IP あたり 5 分間に最大 10 回のログイン要求です。カウントはプロセスメモリ上にあり、再起動でクリアされます（単一コンテナのデプロイなら十分です）。
>
> **ログイン記録**：すべての試行（クライアント / 管理コンソール、成功 / 失敗）が、ユーザー名・送信元 IP・
> User-Agent・成否とともに記録され、30 日間保持されます（`login_records` テーブル）。管理画面はまだこの部分に対応していないため、当面は API で確認してください：
>
> ```bash
> curl -H "Authorization: Bearer <管理コンソールのトークン>" \
>   "http://127.0.0.1:21077/api/v1/admin/logins?onlyFailed=true&limit=20"
> ```
>
> リバースプロキシの背後にデプロイする場合、送信元 IP は `X-Forwarded-For` の先頭の値を使います。ただしこのヘッダーを信頼するのは
> **直接の接続相手がプライベートネットワークかループバックの場合のみ**です。パブリックから直接接続して偽装しても制限は回避できません。

> アカウントをまとめて作りたい場合：`.env` で `OMIOCLINK_ALLOW_REGISTRATION=true` → `docker compose up -d` → クライアントから自己登録 → 再度 `false` に戻して `up -d`。または管理者がコンソールでアカウントを作成し、登録スイッチはオフのままにします

---

## 8. デバッグ

### ローカルでサービスを起動し、コードの変更を即座に反映する

```bash
cd server
uv sync
uv run uvicorn app.main:app --host 0.0.0.0 --port 21077 --reload
```

- `--reload` を付けると 1 行保存するたびに自動で再起動し、クライアントはそのままローカルの `127.0.0.1:21077` に接続できます
- API ドキュメントを見たい場合：`OMIOCLINK_DOCS_ENABLED=true uv run uvicorn app.main:app --port 21077 --reload`、
  その後 `http://127.0.0.1:21077/docs` を開きます
- スモークテスト：`curl http://127.0.0.1:21077/api/v1/health`、`curl http://127.0.0.1:21077/api/v1/server/info`
- ローカルの管理コンソール：`http://127.0.0.1:21077/admin` を直接開きます。初回は管理者パスワードの設定を求められます（パスワードは `./omioclink.db` に保存）

> ローカルで動かす場合、データベースは `./omioclink.db`、データディレクトリは `./data` です（`config.py` の既定値）。コンテナ内の `/app/data` とは互いに影響しません

### 稼働中のコンテナの調査

```bash
docker compose ps                     # healthy か unhealthy か
docker compose logs -f server         # ログを追う（uvicorn のアクセスログ + 未処理例外のスタック）
docker compose exec server python -c "import app; print(app.__version__)"   # コンテナ内の実際のバージョン
docker compose exec server ls -l /app/data                                  # データボリュームはマウントされているか
```

- イベントループが止まった疑いがある場合は `OMIOCLINK_DEBUG_TASKS=1` でコンテナを起動します。0.5 秒ごとにイベントループ内のすべてのタスクを
  ファイル名:行番号:関数の形式で標準出力に出力します（「API が返らない、ログも動かない」といったハングの調査に最も直接的な方法です）
- コンテナは非 root ユーザー `omioclink` で動作し、`exec` で入った先も同じユーザーです。ファイルの変更やパッケージのインストールは Dockerfile を変更してください

---

## 9. テストと静的検査

```bash
cd server
uv run pytest                # テスト（1 件あたり 20s タイムアウト。ハングすると失敗とスタックの形で表面化します）
uv run ruff check .          # 静的検査（行幅 100、ルールは pyproject）
uv run mypy                  # 型チェック（strict）
```

3 つすべてがクリーンである必要があります。CI は push と PR のたびに同じ 3 つに加えてバージョン番号のドリフト検査を実行します

---

## 10. データ、バックアップ、アップグレード

| 項目 | 値 |
| --- | --- |
| データボリューム | `omioclink_server-data` → `/app/data` |
| 中身 | `omioclink.db`（SQLite：アカウント、フレンド、ルーム、プラグイン購読、管理者パスワードのハッシュ）+ `avatars/` + `jwt-secret`（サーバーが自動生成する署名鍵） |
| バックアップ | ボリュームをアーカイブするだけです（例、ベースイメージは任意）：`docker run --rm -v omioclink_server-data:/data -v "$PWD":/backup alpine tar czf /backup/omioclink-data.tgz -C /data .` |
| 復元 | 逆の操作：`docker run --rm -v omioclink_server-data:/data -v "$PWD":/backup alpine tar xzf /backup/omioclink-data.tgz -C /data` |
| アップグレード | `docker compose pull && docker compose up -d`（オフライン環境では方法 2 で tar を再インポート） |
| ロールバック | `.env` で `OMIOCLINK_IMAGE=omioc/omioclink:v<旧バージョン>` → `docker compose up -d` |

アバターと SQLite は同じボリュームにあるため、1 回のバックアップで全体を取得できます。`down -v` はボリュームを削除するので、バックアップなしで実行しないでください

---

## 11. よくある質問

| 症状 | 原因 / 対処 |
| --- | --- |
| `docker compose up` が「.env に OMIOCLINK_JWT_SECRET を設定してください」と表示する | それは旧バージョン（1.0.5 以前）です。新しいバージョンでは空のままで構いません。サーバーが鍵を自動生成し、データボリュームの `jwt-secret` に保存します |
| `/admin` を開くとパスワード設定を求められる | 正常です。管理コンソールは初回利用時に管理者パスワードの設定が必要です（以前はトークンを入力しました）。設定すればログインできます |
| 管理コンソールのパスワードを忘れた | データベースの `admin_account` の行を削除して再設定します（コマンドは第 7 章にあります） |
| 古い `.env` の `OMIOCLINK_ADMIN_TOKEN` はまだ使える？ | 「管理者パスワードの設定」の前なら移行用トークンとして使えます。設定後は無効になるので、その行を削除してください |
| `/docs` を開くと 404 | `OMIOCLINK_DOCS_ENABLED=false`（既定値）です。デバッグ時に一時的に `true` にしてください |
| `docker ps` が `unhealthy` | 多くの場合、データベースやデータディレクトリの権限、または JWT 鍵が要件を満たしていないためです。まず `docker compose logs server` を確認してください |
| クライアントが接続できないのにコンテナは healthy | TCP `21077` を許可してください。ドメイン + リバースプロキシの場合は `OMIOCLINK_BIND_ADDR` とリバースプロキシの向き先が一致しているか確認してください。`http/ws` の平文を使う場合はクライアント側で平文を許可する必要があります |
| 接続はできるが音声のホールパンチングに失敗する | 「リレーなし」アーキテクチャの代償で、サーバーとは関係ありません。対称型 NAT や UDP を遮断するネットワークでは失敗します。まず自前 STUN を有効にし（第 6 章）、その後クライアントの案内に従ってネットワークを変えてください |
| `.env` を変更しても反映されない | 環境変数はコンテナ起動時に読み込まれます。変更後は `docker compose up -d` で作り直してください |
| 待ち受けポートを変えたい | `ports` は `deploy/docker-compose.yml` と `server/docker-compose.yml` にあります（両側を一緒に変更してください）。クライアントには `<host>:<port>` を指定します |
