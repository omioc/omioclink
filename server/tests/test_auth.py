"""账号接口测试。"""

from pathlib import Path

from fastapi.testclient import TestClient

from app.main import create_app
from tests.conftest import PASSWORD, auth_headers, make_settings, register_user

#: 改密码用例用的新口令
NEW_PASSWORD = "s3cret-password-2"


def test_register_returns_token_and_profile(client: TestClient) -> None:
    response = client.post(
        "/api/v1/auth/register",
        json={"username": "alice", "password": PASSWORD, "displayName": "小明"},
    )
    assert response.status_code == 201
    body = response.json()
    assert body["tokenType"] == "bearer"
    assert body["expiresIn"] > 0
    assert body["user"]["username"] == "alice"
    assert body["user"]["displayName"] == "小明"
    assert body["user"]["online"] is False
    assert "password" not in body["user"]


def test_register_duplicate_username_conflicts(client: TestClient) -> None:
    register_user(client, "alice")
    response = client.post(
        "/api/v1/auth/register", json={"username": "alice", "password": PASSWORD}
    )
    assert response.status_code == 409
    assert response.json()["code"] == "username_taken"


def test_register_rejects_short_password_and_bad_username(client: TestClient) -> None:
    short = client.post(
        "/api/v1/auth/register", json={"username": "alice", "password": "1234"}
    )
    assert short.status_code == 422
    assert short.json()["code"] == "invalid_request"

    bad_name = client.post(
        "/api/v1/auth/register", json={"username": "a b", "password": PASSWORD}
    )
    assert bad_name.status_code == 422


def test_login_and_me(client: TestClient) -> None:
    token, user_id = register_user(client, "alice")

    login = client.post(
        "/api/v1/auth/login", json={"username": "alice", "password": PASSWORD}
    )
    assert login.status_code == 200
    assert login.json()["user"]["id"] == user_id

    me = client.get("/api/v1/auth/me", headers=auth_headers(token))
    assert me.status_code == 200
    assert me.json()["username"] == "alice"


def test_login_with_wrong_password_or_unknown_user(client: TestClient) -> None:
    register_user(client, "alice")
    wrong = client.post(
        "/api/v1/auth/login", json={"username": "alice", "password": "not-the-password"}
    )
    assert wrong.status_code == 401
    assert wrong.json()["code"] == "bad_credentials"

    unknown = client.post(
        "/api/v1/auth/login", json={"username": "ghost", "password": PASSWORD}
    )
    assert unknown.status_code == 401


def test_me_requires_valid_token(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    assert client.get("/api/v1/auth/me").status_code == 401
    assert client.get("/api/v1/auth/me", headers=auth_headers("bad-token")).status_code == 401

    # 用户被删除后 token 立即失效
    forged = token[:-2] + ("aa" if not token.endswith("aa") else "bb")
    assert client.get("/api/v1/auth/me", headers=auth_headers(forged)).status_code == 401


def test_update_profile(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    response = client.patch(
        "/api/v1/auth/me",
        json={"displayName": "小明"},
        headers=auth_headers(token),
    )
    assert response.status_code == 200
    assert response.json()["displayName"] == "小明"

    # 持久化了：再查一次仍是新昵称
    me = client.get("/api/v1/auth/me", headers=auth_headers(token))
    assert me.json()["displayName"] == "小明"


def test_update_profile_ignores_client_supplied_avatar(client: TestClient) -> None:
    """头像值是服务端算出来的内容哈希，不接受客户端自己写。"""
    token, _ = register_user(client, "alice")
    response = client.patch(
        "/api/v1/auth/me",
        json={"displayName": "小明", "avatar": "cat"},
        headers=auth_headers(token),
    )
    assert response.status_code == 200
    assert response.json()["avatar"] is None


def test_update_profile_rejects_empty_or_overlong_name(client: TestClient) -> None:
    token, _ = register_user(client, "alice")

    empty = client.patch(
        "/api/v1/auth/me", json={"displayName": ""}, headers=auth_headers(token)
    )
    assert empty.status_code == 422

    too_long = client.patch(
        "/api/v1/auth/me", json={"displayName": "字" * 49}, headers=auth_headers(token)
    )
    assert too_long.status_code == 422

    # 只改头像时昵称保持不变
    avatar_only = client.patch(
        "/api/v1/auth/me", json={"avatar": "dog"}, headers=auth_headers(token)
    )
    assert avatar_only.status_code == 200
    assert avatar_only.json()["displayName"] == "alice"


def test_change_password_revokes_old_tokens(client: TestClient) -> None:
    old_token, _ = register_user(client, "alice")

    changed = client.post(
        "/api/v1/auth/password",
        json={"currentPassword": PASSWORD, "newPassword": NEW_PASSWORD},
        headers=auth_headers(old_token),
    )
    assert changed.status_code == 200, changed.text
    new_token = changed.json()["accessToken"]
    assert new_token != old_token

    # 旧令牌立即失效（不需要等过期），本机换到的新令牌可用
    revoked = client.get("/api/v1/auth/me", headers=auth_headers(old_token))
    assert revoked.status_code == 401
    assert revoked.json()["code"] == "token_revoked"
    assert client.get("/api/v1/auth/me", headers=auth_headers(new_token)).status_code == 200

    # 新密码能登录，旧密码不能
    assert (
        client.post(
            "/api/v1/auth/login", json={"username": "alice", "password": NEW_PASSWORD}
        ).status_code
        == 200
    )
    assert (
        client.post(
            "/api/v1/auth/login", json={"username": "alice", "password": PASSWORD}
        ).status_code
        == 401
    )


def test_change_password_requires_the_current_one(client: TestClient) -> None:
    token, _ = register_user(client, "alice")

    response = client.post(
        "/api/v1/auth/password",
        json={"currentPassword": "not-the-password", "newPassword": NEW_PASSWORD},
        headers=auth_headers(token),
    )
    # 刻意用 403 而非 401：401 会让客户端误判为「登录态失效」而退出登录
    assert response.status_code == 403
    assert response.json()["code"] == "bad_current_password"

    # 密码没被改掉，原令牌仍然有效
    assert (
        client.post(
            "/api/v1/auth/login", json={"username": "alice", "password": PASSWORD}
        ).status_code
        == 200
    )
    assert client.get("/api/v1/auth/me", headers=auth_headers(token)).status_code == 200


def test_change_password_rejects_reused_one(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    response = client.post(
        "/api/v1/auth/password",
        json={"currentPassword": PASSWORD, "newPassword": PASSWORD},
        headers=auth_headers(token),
    )
    assert response.status_code == 422
    assert response.json()["code"] == "password_unchanged"


def test_change_password_respects_server_minimum(tmp_path: Path) -> None:
    """服务器把口令下限配成 12 位时，接口要按 12 位判，而不是 schema 里的 8 位。"""
    settings = make_settings(tmp_path).model_copy(update={"password_min_length": 12})
    with TestClient(create_app(settings)) as client:
        token, _ = register_user(client, "alice")
        response = client.post(
            "/api/v1/auth/password",
            json={"currentPassword": PASSWORD, "newPassword": "eleven-char"},
            headers=auth_headers(token),
        )
        assert response.status_code == 422
        assert response.json()["code"] == "weak_password"
