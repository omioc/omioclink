"""登录限流：管理台锁定、客户端账号退避、来源 IP 窗口、登录记录。

这些用例都跑在真实的 HTTP 层（TestClient）：限流接在路由里，
光测「计数器能不能数」证明不了「接口真的会拒绝」。
"""

from typing import Any, cast

from fastapi import FastAPI
from fastapi.testclient import TestClient

from app.core.ratelimit import LoginLimits
from tests.conftest import (
    ADMIN_PASSWORD,
    PASSWORD,
    admin_login,
    register_user,
)

#: 一定不对的密码（长度合法，免得先被 schema 挡掉）
WRONG = "definitely-wrong-password"


def _login(
    client: TestClient, username: str, password: str
) -> tuple[int, dict[str, Any]]:
    response = client.post(
        "/api/v1/auth/login", json={"username": username, "password": password}
    )
    return response.status_code, response.json()


def _admin_login(client: TestClient, password: str) -> tuple[int, dict[str, Any]]:
    response = client.post("/api/v1/admin/login", json={"password": password})
    return response.status_code, response.json()


def test_客户端登录按来源限流(client: TestClient) -> None:
    """同一来源 5 分钟内最多 10 次登录请求（成功也计入）。"""
    register_user(client, "alice")

    for _ in range(10):
        status, body = _login(client, "alice", PASSWORD)
        assert status == 200, body

    status, body = _login(client, "alice", PASSWORD)
    assert status == 429, body
    assert body["code"] == "login_rate_limited"
    assert body["retryAfter"] >= 1


def test_同一账号连续输错后指数退避(client: TestClient) -> None:
    register_user(client, "alice")

    # 前 3 次只是普通的 401（正常用户手滑两下不该被卡）
    for _ in range(3):
        status, body = _login(client, "alice", WRONG)
        assert status == 401, body
        assert body["code"] == "bad_credentials"

    # 第 4 次密码仍然错（401），但它把退避计时器点上了
    status, body = _login(client, "alice", WRONG)
    assert status == 401, body

    # 第 5 次开始要求等待，而且这时连正确密码也不放行
    status, body = _login(client, "alice", PASSWORD)
    assert status == 429, body
    assert body["code"] == "login_backoff"
    assert body["retryAfter"] >= 1


def test_别的账号不受影响(client: TestClient) -> None:
    """退避是按用户名计的，不能因为一个账号被猜就连累别人。"""
    register_user(client, "alice")
    register_user(client, "bob")
    for _ in range(4):
        _login(client, "alice", WRONG)

    status, body = _login(client, "bob", PASSWORD)
    assert status == 200, body


def test_管理台连错五次锁五分钟(client: TestClient) -> None:
    admin_login(client)  # 首次调用会设置管理员密码

    for _ in range(4):
        status, body = _admin_login(client, WRONG)
        assert status == 401, body
        assert body["code"] == "bad_admin_password"

    status, body = _admin_login(client, WRONG)
    assert status == 429, body
    assert body["code"] == "admin_locked"
    assert body["retryAfter"] >= 1

    # 锁定期间正确密码也不放行：否则「猜对了就能进」，锁定等于没有
    status, body = _admin_login(client, ADMIN_PASSWORD)
    assert status == 429, body


def test_管理台锁定会到期(client: TestClient) -> None:
    admin_login(client)
    clock = {"now": 1000.0}
    app = cast(FastAPI, client.app)
    app.state.login_limits = LoginLimits.with_clock(lambda: clock["now"])

    for _ in range(5):
        _admin_login(client, WRONG)
    status, _ = _admin_login(client, ADMIN_PASSWORD)
    assert status == 429

    # 5 分钟之后自动解锁（假时钟，不真等）
    clock["now"] += 301
    status, body = _admin_login(client, ADMIN_PASSWORD)
    assert status == 200, body


def test_登录记录能在管理台查到(client: TestClient) -> None:
    headers = admin_login(client)
    register_user(client, "alice")
    _login(client, "alice", PASSWORD)
    _login(client, "alice", WRONG)

    response = client.get("/api/v1/admin/logins", headers=headers)
    assert response.status_code == 200, response.text
    items = response.json()["items"]
    assert items, "登录记录不该是空的"
    # 倒序：最新的一条就是刚才那次失败
    assert items[0]["username"] == "alice"
    assert items[0]["success"] is False
    assert items[0]["source"] == "client"
    assert items[0]["ip"], "来源 IP 要记下来"
    assert any(item["success"] for item in items), "成功登录也要有一条"

    only_failed = client.get(
        "/api/v1/admin/logins?onlyFailed=true", headers=headers
    ).json()["items"]
    assert only_failed and all(item["success"] is False for item in only_failed)
