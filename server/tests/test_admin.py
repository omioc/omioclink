"""Web 管理台与 /api/v1/admin/* 测试。

管理台从「环境变量里的令牌」改成了「管理员密码登录」（哈希存在 admin_account 表），
所以这里的鉴权用例围绕三件事：首次设置密码、密码登录/改密码、以及旧版
``OMIOCLINK_ADMIN_TOKEN`` 的平滑迁移。
"""

import contextlib
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest
from fastapi.testclient import TestClient
from starlette.testclient import WebSocketTestSession
from starlette.websockets import WebSocketDisconnect

from app.main import create_app
from tests.conftest import (
    ADMIN_PASSWORD,
    PASSWORD,
    admin_login,
    auth_headers,
    create_room,
    make_settings,
    register_user,
    ws_url,
)

#: 旧版（OMIOCLINK_ADMIN_TOKEN）的管理令牌：只为「平滑迁移」用例保留
LEGACY_TOKEN = "test-admin-token-please-change"


def legacy_headers(token: str = LEGACY_TOKEN) -> dict[str, str]:
    return {"X-Admin-Token": token}


@contextmanager
def running_client(
    tmp_path: Path,
    *,
    admin_token: str | None = None,
    docs_enabled: bool = False,
    allow_registration: bool = True,
) -> Iterator[TestClient]:
    app = create_app(
        make_settings(
            tmp_path,
            allow_registration=allow_registration,
            docs_enabled=docs_enabled,
            admin_token=admin_token,
        )
    )
    with TestClient(app) as client:
        yield client


def _join_room(
    client: TestClient, stack: contextlib.ExitStack, token: str, room_id: str
) -> tuple[WebSocketTestSession, dict]:
    """在 ExitStack 里进入一条 WebSocket 会话并入房（只 __enter__ 一次）。"""
    ws = stack.enter_context(client.websocket_connect(ws_url(token)))
    hello = ws.receive_json()
    assert hello["type"] == "hello"
    ws.send_json({"type": "join_room", "roomId": room_id})
    state = ws.receive_json()
    assert state["type"] == "room_state", state
    return ws, hello


# --------------------------------------------------------------------------- #
# 管理台常开（不再依赖 OMIOCLINK_ADMIN_TOKEN）
# --------------------------------------------------------------------------- #
def test_admin_page_is_always_served(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        response = client.get("/admin")
        assert response.status_code == 200
        assert response.headers["content-type"].startswith("text/html")
        assert "OmiocLink 管理" in response.text


def test_admin_page_uses_brand_logo(tmp_path: Path) -> None:
    """管理页的品牌图标：页面引用它，路由取到的是真正的 PNG。"""
    with running_client(tmp_path) as client:
        page = client.get("/admin")
        assert 'href="/admin/logo.png"' in page.text, "页签图标"
        assert 'src="/admin/logo.png"' in page.text, "页头图标"

        logo = client.get("/admin/logo.png")
        assert logo.status_code == 200
        assert logo.headers["content-type"] == "image/png"
        assert logo.content.startswith(b"\x89PNG\r\n\x1a\n")


def test_admin_api_is_registered_without_any_token(tmp_path: Path) -> None:
    """管理接口不再「没配令牌就不注册」：设备上是 401（要登录），不是 404。"""
    with running_client(tmp_path) as client:
        response = client.get("/api/v1/admin/overview")
        assert response.status_code == 401


def test_admin_page_renders_password_flow(tmp_path: Path) -> None:
    """页面自己不带任何密钥：第一次打开时由 JS 问接口要状态、再弹设置密码/登录框。"""
    with running_client(tmp_path) as client:
        page = client.get("/admin").text
        assert "设置管理员密码" in page
        assert "管理员登录" in page
        assert "Authorization: 'Bearer '" in page, "管理接口要走管理员登录态令牌"
        assert "'X-Admin-Token':" not in page, "页面不该再发旧令牌"
        assert "omioclink.adminToken" in page, "旧 localStorage 键要被清掉"


def test_docs_hidden_by_default(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        assert client.get("/docs").status_code == 404
        assert client.get("/openapi.json").status_code == 404
        assert client.get("/redoc").status_code == 404


def test_docs_available_when_enabled(tmp_path: Path) -> None:
    with running_client(tmp_path, docs_enabled=True) as client:
        assert client.get("/docs").status_code == 200
        schema = client.get("/openapi.json").json()
        assert schema["info"]["title"]
        assert "/api/v1/rooms" in schema["paths"]


# --------------------------------------------------------------------------- #
# 首次设置密码
# --------------------------------------------------------------------------- #
def test_session_reports_need_setup(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        body = client.get("/api/v1/admin/session").json()
        assert body["initialized"] is False
        assert body["authenticated"] is False
        assert body["legacyTokenConfigured"] is False
        assert body["passwordMinLength"] == 8
        assert body["username"] is None


def test_setup_password_then_session_is_authenticated(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        created = client.post("/api/v1/admin/setup", json={"password": ADMIN_PASSWORD})
        assert created.status_code == 201, created.text
        body = created.json()
        assert body["username"] == "admin"
        assert body["expiresIn"] > 0
        token = body["accessToken"]

        session = client.get("/api/v1/admin/session", headers=auth_headers(token)).json()
        assert session["initialized"] is True
        assert session["authenticated"] is True
        assert session["username"] == "admin"


def test_setup_rejects_weak_password(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        response = client.post("/api/v1/admin/setup", json={"password": "1234"})
        assert response.status_code == 422
        assert response.json()["code"] == "weak_password"
        # 失败不能留下半个管理员：状态仍是「还没设置」
        assert client.get("/api/v1/admin/session").json()["initialized"] is False


def test_setup_twice_conflicts(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        first = client.post("/api/v1/admin/setup", json={"password": ADMIN_PASSWORD})
        assert first.status_code == 201

        again = client.post("/api/v1/admin/setup", json={"password": "another-password"})
        assert again.status_code == 409
        assert again.json()["code"] == "admin_already_initialized"


# --------------------------------------------------------------------------- #
# 登录与管理接口鉴权
# --------------------------------------------------------------------------- #
def test_login_before_setup_conflicts(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        response = client.post("/api/v1/admin/login", json={"password": ADMIN_PASSWORD})
        assert response.status_code == 409
        assert response.json()["code"] == "admin_not_initialized"


def test_login_rejects_wrong_password(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin_login(client)

        bad = client.post("/api/v1/admin/login", json={"password": "nope-nope-nope"})
        assert bad.status_code == 401
        assert bad.json()["code"] == "bad_admin_password"

        ok = client.post("/api/v1/admin/login", json={"password": ADMIN_PASSWORD})
        assert ok.status_code == 200
        assert client.get(
            "/api/v1/admin/overview", headers=auth_headers(ok.json()["accessToken"])
        ).status_code == 200


def test_admin_api_rejects_missing_or_broken_session(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin_login(client)

        missing = client.get("/api/v1/admin/overview")
        assert missing.status_code == 401
        assert missing.json()["code"] == "admin_session_invalid"

        broken = client.get("/api/v1/admin/overview", headers=auth_headers("not-a-jwt"))
        assert broken.status_code == 401


def test_user_token_cannot_act_as_admin(tmp_path: Path) -> None:
    """用户 JWT 不能当管理员用：管理接口只认 scope=admin 的令牌。"""
    with running_client(tmp_path) as client:
        admin_login(client)
        token, _ = register_user(client, "alice")
        response = client.get("/api/v1/admin/overview", headers=auth_headers(token))
        assert response.status_code == 401


def test_admin_token_cannot_act_as_user(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        assert client.get("/api/v1/auth/me", headers=admin).status_code == 401


def test_change_password_invalidates_old_session(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        old = admin_login(client)
        changed = client.post(
            "/api/v1/admin/password",
            json={"currentPassword": ADMIN_PASSWORD, "newPassword": "brand-new-password"},
            headers=old,
        )
        assert changed.status_code == 200, changed.text
        new = auth_headers(changed.json()["accessToken"])

        # 旧令牌立刻失效（口令指纹变了），这台换到的新令牌可用
        assert client.get("/api/v1/admin/overview", headers=old).status_code == 401
        assert client.get("/api/v1/admin/overview", headers=new).status_code == 200

        # 旧密码登不进来，新密码可以
        stale = client.post("/api/v1/admin/login", json={"password": ADMIN_PASSWORD})
        assert stale.status_code == 401
        fresh = client.post("/api/v1/admin/login", json={"password": "brand-new-password"})
        assert fresh.status_code == 200


def test_change_password_requires_current_password(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        response = client.post(
            "/api/v1/admin/password",
            json={"currentPassword": "wrong-password", "newPassword": "brand-new-password"},
            headers=admin,
        )
        assert response.status_code == 403
        assert response.json()["code"] == "bad_current_password"


# --------------------------------------------------------------------------- #
# 旧版 OMIOCLINK_ADMIN_TOKEN 的平滑迁移
# --------------------------------------------------------------------------- #
def test_legacy_token_still_works_before_setup(tmp_path: Path) -> None:
    """老部署（.env 里还有 OMIOCLINK_ADMIN_TOKEN）升级后不会当场用不了。"""
    with running_client(tmp_path, admin_token=LEGACY_TOKEN) as client:
        session = client.get("/api/v1/admin/session").json()
        assert session["initialized"] is False
        assert session["legacyTokenConfigured"] is True

        assert client.get("/api/v1/admin/overview", headers=legacy_headers()).status_code == 200
        wrong = client.get("/api/v1/admin/overview", headers=legacy_headers("nope"))
        assert wrong.status_code == 401
        assert wrong.json()["code"] == "bad_admin_token"


def test_setup_retires_legacy_token(tmp_path: Path) -> None:
    """设好管理员密码之后旧令牌立即作废，只剩密码登录这一条路。"""
    with running_client(tmp_path, admin_token=LEGACY_TOKEN) as client:
        admin = admin_login(client)  # 走的是新版「设置密码」

        retired = client.get("/api/v1/admin/overview", headers=legacy_headers())
        assert retired.status_code == 401
        assert retired.json()["code"] == "admin_token_retired"

        assert client.get("/api/v1/admin/overview", headers=admin).status_code == 200


def test_legacy_header_unknown_when_not_configured(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        response = client.get("/api/v1/admin/overview", headers=legacy_headers())
        assert response.status_code == 401
        assert response.json()["code"] == "bad_admin_token"


# --------------------------------------------------------------------------- #
# 概览与注册开关
# --------------------------------------------------------------------------- #
def test_overview_reports_state(tmp_path: Path) -> None:
    with running_client(tmp_path, allow_registration=False) as client:
        admin = admin_login(client)
        # 注册关闭，只能由管理端建号
        client.post(
            "/api/v1/admin/users",
            json={"username": "alice", "password": PASSWORD},
            headers=admin,
        )
        token = client.post(
            "/api/v1/auth/login", json={"username": "alice", "password": PASSWORD}
        ).json()["accessToken"]
        create_room(client, token)

        body = client.get("/api/v1/admin/overview", headers=admin).json()
        assert body["userCount"] == 1
        assert body["roomCount"] == 1
        assert body["publicRoomCount"] == 1
        assert body["livePeerCount"] == 0
        assert body["liveRoomCount"] == 0
        assert body["allowRegistration"] is False
        assert body["docsEnabled"] is False
        assert body["version"]


def test_registration_toggle_takes_effect_immediately(tmp_path: Path) -> None:
    with running_client(tmp_path, allow_registration=False) as client:
        admin = admin_login(client)
        blocked = client.post(
            "/api/v1/auth/register", json={"username": "alice", "password": PASSWORD}
        )
        assert blocked.status_code == 403

        opened = client.post(
            "/api/v1/admin/registration", json={"allow": True}, headers=admin
        )
        assert opened.status_code == 200
        assert opened.json()["allowRegistration"] is True

        created = client.post(
            "/api/v1/auth/register", json={"username": "alice", "password": PASSWORD}
        )
        assert created.status_code == 201

        closed = client.post(
            "/api/v1/admin/registration", json={"allow": False}, headers=admin
        )
        assert closed.json()["allowRegistration"] is False
        again = client.post(
            "/api/v1/auth/register", json={"username": "bob", "password": PASSWORD}
        )
        assert again.status_code == 403


# --------------------------------------------------------------------------- #
# 账号
# --------------------------------------------------------------------------- #
def test_create_user_without_opening_registration(tmp_path: Path) -> None:
    with running_client(tmp_path, allow_registration=False) as client:
        admin = admin_login(client)
        created = client.post(
            "/api/v1/admin/users",
            json={"username": "alice", "password": PASSWORD, "displayName": "小明"},
            headers=admin,
        )
        assert created.status_code == 201, created.text
        body = created.json()
        assert body["username"] == "alice"
        assert body["displayName"] == "小明"
        assert body["online"] is False

        # 注册仍是关闭的
        assert client.post(
            "/api/v1/auth/register", json={"username": "bob", "password": PASSWORD}
        ).status_code == 403

        # 但新建的账号可以登录
        login = client.post(
            "/api/v1/auth/login", json={"username": "alice", "password": PASSWORD}
        )
        assert login.status_code == 200

        duplicate = client.post(
            "/api/v1/admin/users",
            json={"username": "alice", "password": PASSWORD},
            headers=admin,
        )
        assert duplicate.status_code == 409
        assert duplicate.json()["code"] == "username_taken"


def test_create_user_validates_input(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        bad_name = client.post(
            "/api/v1/admin/users",
            json={"username": "a b", "password": PASSWORD},
            headers=admin,
        )
        assert bad_name.status_code == 422
        short_password = client.post(
            "/api/v1/admin/users",
            json={"username": "alice", "password": "1234"},
            headers=admin,
        )
        assert short_password.status_code == 422


def test_list_users_and_filter(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        client.post(
            "/api/v1/admin/users",
            json={"username": "alice", "password": PASSWORD, "displayName": "小明"},
            headers=admin,
        )
        client.post(
            "/api/v1/admin/users",
            json={"username": "bob", "password": PASSWORD, "displayName": "小红"},
            headers=admin,
        )

        all_users = client.get("/api/v1/admin/users", headers=admin).json()
        assert all_users["total"] == 2
        assert [item["username"] for item in all_users["items"]] == ["alice", "bob"]

        by_name = client.get(
            "/api/v1/admin/users", params={"query": "bob"}, headers=admin
        ).json()
        assert by_name["total"] == 1
        assert by_name["items"][0]["displayName"] == "小红"

        by_display = client.get(
            "/api/v1/admin/users", params={"query": "小明"}, headers=admin
        ).json()
        assert by_display["total"] == 1
        assert by_display["items"][0]["username"] == "alice"


def test_disable_user_blocks_login_and_invalidates_token(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        token, user_id = register_user(client, "alice")
        assert client.get("/api/v1/auth/me", headers=auth_headers(token)).status_code == 200

        disabled = client.patch(
            f"/api/v1/admin/users/{user_id}", json={"disabled": True}, headers=admin
        )
        assert disabled.status_code == 200
        assert disabled.json()["disabled"] is True

        # 已签发的令牌立即失效
        stale = client.get("/api/v1/auth/me", headers=auth_headers(token))
        assert stale.status_code == 401
        assert stale.json()["code"] == "account_disabled"

        # 也不能再登录
        login = client.post(
            "/api/v1/auth/login", json={"username": "alice", "password": PASSWORD}
        )
        assert login.status_code == 403
        assert login.json()["code"] == "account_disabled"

        # 启用后恢复
        enabled = client.patch(
            f"/api/v1/admin/users/{user_id}", json={"disabled": False}, headers=admin
        )
        assert enabled.json()["disabled"] is False
        assert client.post(
            "/api/v1/auth/login", json={"username": "alice", "password": PASSWORD}
        ).status_code == 200


def test_disable_kicks_live_session(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        token, user_id = register_user(client, "alice")

        with contextlib.ExitStack() as stack:
            ws = stack.enter_context(client.websocket_connect(ws_url(token)))
            assert ws.receive_json()["type"] == "hello"

            response = client.patch(
                f"/api/v1/admin/users/{user_id}",
                json={"disabled": True},
                headers=admin,
            )
            assert response.status_code == 200

            kicked = ws.receive_json()
            assert kicked["type"] == "kicked"
            assert kicked["reason"] == "account_disabled"
            with pytest.raises(WebSocketDisconnect):
                ws.receive_json()


def test_disabled_user_cannot_open_websocket(tmp_path: Path) -> None:
    """禁用必须在信令这条路上也生效，否则被踢的人能立刻重连回来。"""
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        token, user_id = register_user(client, "alice")
        client.patch(
            f"/api/v1/admin/users/{user_id}", json={"disabled": True}, headers=admin
        )

        with (
            pytest.raises(WebSocketDisconnect) as info,
            client.websocket_connect(ws_url(token)) as ws,
        ):
            ws.receive_json()
        assert info.value.code == 4401


def test_user_list_reports_disabled_flag(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        _, user_id = register_user(client, "alice")
        client.patch(
            f"/api/v1/admin/users/{user_id}", json={"disabled": True}, headers=admin
        )

        body = client.get("/api/v1/admin/users", headers=admin).json()
        assert body["items"][0]["disabled"] is True
        assert body["items"][0]["online"] is False


def test_delete_user_cleans_rooms_memberships_and_friendships(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        alice_token, alice_id = register_user(client, "alice")
        bob_token, _ = register_user(client, "bob")

        # 互加好友
        client.post(
            "/api/v1/friends/requests", json={"username": "bob"}, headers=auth_headers(alice_token)
        )
        incoming = client.get("/api/v1/friends/requests", headers=auth_headers(bob_token)).json()
        client.post(
            f"/api/v1/friends/requests/{incoming['items'][0]['id']}",
            json={"accept": True},
            headers=auth_headers(bob_token),
        )
        assert client.get("/api/v1/friends", headers=auth_headers(bob_token)).json()["total"] == 1

        room_id = create_room(client, alice_token, name="alice 的房间")["roomId"]
        # bob 进过这个房间
        with contextlib.ExitStack() as stack:
            ws = stack.enter_context(client.websocket_connect(ws_url(bob_token)))
            assert ws.receive_json()["type"] == "hello"
            ws.send_json({"type": "join_room", "roomId": room_id})
            assert ws.receive_json()["type"] == "room_state"

            deleted = client.delete(f"/api/v1/admin/users/{alice_id}", headers=admin)
            assert deleted.status_code == 204

            # 房主被删，房间解散，房内其他人收到通知
            closed = ws.receive_json()
            assert closed["type"] == "room_closed"
            assert closed["reason"] == "owner_deleted"
            with pytest.raises(WebSocketDisconnect):
                ws.receive_json()

        # 令牌失效、账号消失、房间消失、好友关系清空
        assert client.get("/api/v1/auth/me", headers=auth_headers(alice_token)).status_code == 401
        users = client.get("/api/v1/admin/users", headers=admin).json()
        assert [item["username"] for item in users["items"]] == ["bob"]
        assert client.get("/api/v1/admin/rooms", headers=admin).json()["total"] == 0
        assert client.get("/api/v1/friends", headers=auth_headers(bob_token)).json()["total"] == 0
        # 其他账号不受影响
        assert client.get("/api/v1/auth/me", headers=auth_headers(bob_token)).status_code == 200


def test_update_or_delete_unknown_user_returns_404(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        assert client.patch(
            "/api/v1/admin/users/999", json={"disabled": True}, headers=admin
        ).status_code == 404
        assert client.delete("/api/v1/admin/users/999", headers=admin).status_code == 404


# --------------------------------------------------------------------------- #
# 房间
# --------------------------------------------------------------------------- #
def test_admin_sees_private_rooms(client_rooms: tuple[TestClient, str, str]) -> None:
    client, public_id, private_id = client_rooms
    admin = admin_login(client)
    admin_rooms = client.get("/api/v1/admin/rooms", headers=admin).json()
    ids = {item["roomId"] for item in admin_rooms["items"]}
    assert ids == {public_id, private_id}
    assert admin_rooms["total"] == 2

    # 普通接口只看得到公开房间
    assert {item["roomId"] for item in client.get("/api/v1/rooms").json()["items"]} == {public_id}


def test_kick_member_broadcasts_and_disconnects(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        alice_token, _ = register_user(client, "alice")
        bob_token, _ = register_user(client, "bob")
        room_id = create_room(client, alice_token)["roomId"]

        with contextlib.ExitStack() as stack:
            ws_a, _ = _join_room(client, stack, alice_token, room_id)
            ws_b, hello_b = _join_room(client, stack, bob_token, room_id)
            assert ws_a.receive_json()["type"] == "member_joined"

            members = client.get(
                f"/api/v1/admin/rooms/{room_id}/members", headers=admin
            ).json()
            assert members["total"] == 2

            kicked = client.post(
                f"/api/v1/admin/rooms/{room_id}/kick",
                json={"peerId": hello_b["peerId"]},
                headers=admin,
            )
            assert kicked.status_code == 200

            assert ws_b.receive_json()["type"] == "kicked"
            left = ws_a.receive_json()
            assert left["type"] == "member_left"
            assert left["peerId"] == hello_b["peerId"]
            with pytest.raises(WebSocketDisconnect):
                ws_b.receive_json()

            remaining = client.get(
                f"/api/v1/admin/rooms/{room_id}/members", headers=admin
            ).json()
            assert [m["username"] for m in remaining["items"]] == ["alice"]


def test_kick_unknown_peer_returns_404(client_rooms: tuple[TestClient, str, str]) -> None:
    client, _public_id, private_id = client_rooms
    admin = admin_login(client)
    unknown = client.post(
        f"/api/v1/admin/rooms/{private_id}/kick",
        json={"peerId": "deadbeef"},
        headers=admin,
    )
    assert unknown.status_code == 404
    assert unknown.json()["code"] == "peer_not_found"


def test_admin_can_delete_any_room(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        alice_token, _ = register_user(client, "alice")
        bob_token, _ = register_user(client, "bob")
        room_id = create_room(client, alice_token, name="别人的房间")["roomId"]

        with contextlib.ExitStack() as stack:
            ws_a, _ = _join_room(client, stack, alice_token, room_id)
            ws_b, _ = _join_room(client, stack, bob_token, room_id)
            assert ws_a.receive_json()["type"] == "member_joined"

            deleted = client.delete(f"/api/v1/admin/rooms/{room_id}", headers=admin)
            assert deleted.status_code == 204

            for socket in (ws_a, ws_b):
                closed = socket.receive_json()
                assert closed["type"] == "room_closed"
                assert closed["reason"] == "closed_by_admin"

        assert client.get(f"/api/v1/rooms/{room_id}").status_code == 404
        assert client.get("/api/v1/admin/rooms", headers=admin).json()["total"] == 0


def test_admin_delete_missing_room(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        admin = admin_login(client)
        response = client.delete("/api/v1/admin/rooms/ZZZZZZ", headers=admin)
        assert response.status_code == 404
        assert response.json()["code"] == "room_not_found"


def test_admin_account_survives_restart(tmp_path: Path) -> None:
    """管理员密码落在库里：重启后仍是「已设置」，老密码能直接登进来。"""
    with running_client(tmp_path) as client:
        admin_login(client)

    with running_client(tmp_path) as client:
        assert client.get("/api/v1/admin/session").json()["initialized"] is True
        login = client.post("/api/v1/admin/login", json={"password": ADMIN_PASSWORD})
        assert login.status_code == 200


# --------------------------------------------------------------------------- #
# 夹具
# --------------------------------------------------------------------------- #
@pytest.fixture()
def client_rooms(tmp_path: Path) -> Iterator[tuple[TestClient, str, str]]:
    """造一个公开房 + 一个私有房，返回 (client, public_id, private_id)。"""
    with running_client(tmp_path) as client:
        token, _ = register_user(client, "alice")
        public_id = create_room(client, token, name="公开房")["roomId"]
        private_id = create_room(client, token, name="私有房", is_public=False)["roomId"]
        yield client, public_id, private_id
