"""测试夹具：每个用例一个独立的临时 SQLite 库与独立应用实例。"""

from collections.abc import Iterator
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.core.config import Settings
from app.main import create_app

PASSWORD = "s3cret-password"

#: 管理台管理员密码（新版用密码登录，不再有自己的令牌环境变量）
ADMIN_PASSWORD = "admin-s3cret-password"


def make_settings(
    tmp_path: Path,
    *,
    allow_registration: bool = True,
    docs_enabled: bool = False,
    admin_token: str | None = None,
) -> Settings:
    """测试基线配置。

    注意 ``allow_registration`` 在这里默认 **True**：绝大多数用例都要先建号。
    生产默认值是关闭，由 ``test_registration_policy.py`` 单独覆盖。
    ``docs_enabled`` / ``admin_token`` 默认关闭，由 ``test_admin.py`` 按需覆盖。
    """
    return Settings(
        database_url=f"sqlite+aiosqlite:///{tmp_path / 'test.db'}",
        # 头像落盘：指到临时目录，别在仓库里造出一个 data/
        data_dir=tmp_path / "data",
        jwt_secret="unit-test-secret-key-32-bytes-min!!",
        heartbeat_interval_seconds=30,
        heartbeat_timeout_seconds=90,
        heartbeat_sweep_seconds=2,
        ice_servers=["stun:test.local:3478"],
        allow_registration=allow_registration,
        docs_enabled=docs_enabled,
        admin_token=admin_token,
    )


@pytest.fixture()
def settings(tmp_path: Path) -> Settings:
    return make_settings(tmp_path)


@pytest.fixture()
def client(settings: Settings) -> Iterator[TestClient]:
    app = create_app(settings)
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture()
def api(settings: Settings) -> str:
    return settings.api_prefix


def register_user(
    client: TestClient, username: str, *, display_name: str | None = None
) -> tuple[str, int]:
    """注册一个账号，返回 (token, user_id)。"""
    response = client.post(
        "/api/v1/auth/register",
        json={
            "username": username,
            "password": PASSWORD,
            "displayName": display_name or username,
        },
    )
    assert response.status_code == 201, response.text
    body = response.json()
    return body["accessToken"], body["user"]["id"]


def auth_headers(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def create_room(
    client: TestClient,
    token: str,
    *,
    name: str = "游戏开黑",
    capacity: int = 5,
    password: str | None = None,
    is_public: bool = True,
) -> dict:
    payload: dict = {"name": name, "capacity": capacity, "isPublic": is_public}
    if password is not None:
        payload["password"] = password
    response = client.post("/api/v1/rooms", json=payload, headers=auth_headers(token))
    assert response.status_code == 201, response.text
    return response.json()


def ws_url(token: str) -> str:
    return f"/ws?token={token}"


def admin_login(client: TestClient, password: str = ADMIN_PASSWORD) -> dict[str, str]:
    """拿到管理接口用的请求头：没初始化就先设置密码，否则直接登录。

    管理台改成「密码登录」之后，测试里要打 ``/api/v1/admin/*`` 都得先有管理员；
    同一个 client 上重复调用是安全的（设置接口只在还没设置时可用）。
    """
    session = client.get("/api/v1/admin/session").json()
    if session["initialized"]:
        response = client.post("/api/v1/admin/login", json={"password": password})
    else:
        response = client.post("/api/v1/admin/setup", json={"password": password})
    assert response.status_code in (200, 201), response.text
    return {"Authorization": f"Bearer {response.json()['accessToken']}"}
