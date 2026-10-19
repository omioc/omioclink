"""注册策略：默认不允许自注册，需通过配置显式开启。"""

from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.core.config import Settings
from app.main import create_app
from tests.conftest import PASSWORD, auth_headers, make_settings, register_user


@contextmanager
def running_client(
    tmp_path: Path, *, allow_registration: bool, database: str | None = None
) -> Iterator[TestClient]:
    """按指定注册策略启动一个应用实例。

    同一个 ``tmp_path`` 会落在同一个 SQLite 文件上，因此可以先用放开注册的实例建号、
    再用关闭注册的实例验证登录。
    """
    settings = make_settings(tmp_path, allow_registration=allow_registration)
    if database is not None:
        settings = settings.model_copy(update={"database_url": database})
    app = create_app(settings)
    with TestClient(app) as client:
        yield client


def test_default_setting_is_registration_closed() -> None:
    """字段默认值必须是关闭——部署时忘配也不会意外开放注册。"""
    field = Settings.model_fields["allow_registration"]
    assert field.default is False


def test_register_is_forbidden_when_closed(tmp_path: Path) -> None:
    with running_client(tmp_path, allow_registration=False) as client:
        response = client.post(
            "/api/v1/auth/register", json={"username": "alice", "password": PASSWORD}
        )
        assert response.status_code == 403
        assert response.json()["code"] == "registration_disabled"
        assert response.json()["message"] == "本服务器未开放注册"


def test_closed_registration_does_not_leak_username_existence(tmp_path: Path) -> None:
    """先判开关再查重名：关闭时无论用户名是否被占用，响应必须完全一致。"""
    with running_client(tmp_path, allow_registration=True) as opener:
        register_user(opener, "taken")

    with running_client(tmp_path, allow_registration=False) as client:
        free = client.post(
            "/api/v1/auth/register", json={"username": "brand-new", "password": PASSWORD}
        )
        occupied = client.post(
            "/api/v1/auth/register", json={"username": "taken", "password": PASSWORD}
        )
        assert free.status_code == occupied.status_code == 403
        assert free.json() == occupied.json()


def test_register_succeeds_when_opened(tmp_path: Path) -> None:
    with running_client(tmp_path, allow_registration=True) as client:
        token, user_id = register_user(client, "alice")
        me = client.get("/api/v1/auth/me", headers=auth_headers(token))
        assert me.status_code == 200
        assert me.json()["id"] == user_id


def test_login_still_works_while_registration_is_closed(tmp_path: Path) -> None:
    with running_client(tmp_path, allow_registration=True) as opener:
        register_user(opener, "alice")

    with running_client(tmp_path, allow_registration=False) as client:
        blocked = client.post(
            "/api/v1/auth/register", json={"username": "bob", "password": PASSWORD}
        )
        assert blocked.status_code == 403

        login = client.post(
            "/api/v1/auth/login", json={"username": "alice", "password": PASSWORD}
        )
        assert login.status_code == 200
        assert login.json()["user"]["username"] == "alice"


@pytest.mark.parametrize("allow_registration", [True, False])
def test_server_info_reports_registration_policy(
    tmp_path: Path, allow_registration: bool
) -> None:
    with running_client(tmp_path, allow_registration=allow_registration) as client:
        body = client.get("/api/v1/server/info").json()
        assert body["allowRegistration"] is allow_registration
