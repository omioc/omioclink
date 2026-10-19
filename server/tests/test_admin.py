"""Web 管理页与 /api/v1/admin/* 测试。"""

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
    PASSWORD,
    auth_headers,
    create_room,
    make_settings,
    register_user,
    ws_url,
)

ADMIN_TOKEN = "test-admin-token-please-change"


def admin_headers(token: str = ADMIN_TOKEN) -> dict[str, str]:
    return {"X-Admin-Token": token}


@contextmanager
def running_client(
    tmp_path: Path,
    *,
    admin_token: str | None = ADMIN_TOKEN,
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
# 关闭态：连路由都不存在
# --------------------------------------------------------------------------- #
def test_admin_routes_absent_without_token(tmp_path: Path) -> None:
    with running_client(tmp_path, admin_token=None) as client:
        assert client.get("/admin").status_code == 404
        assert client.get("/api/v1/admin/overview").status_code == 404
        assert client.get("/api/v1/admin/overview", headers=admin_headers()).status_code == 404
        assert client.post("/api/v1/admin/users", json={}, headers=admin_headers()).status_code == 404


def test_blank_token_counts_as_disabled(tmp_path: Path) -> None:
    with running_client(tmp_path, admin_token="   ") as client:
        assert client.get("/admin").status_code == 404


def test_docs_hidden_by_default(tmp_path: Path) -> None:
    with running_client(tmp_path, admin_token=None) as client:
        assert client.get("/docs").status_code == 404
        assert client.get("/openapi.json").status_code == 404
        assert client.get("/redoc").status_code == 404


def test_docs_available_when_enabled(tmp_path: Path) -> None:
    with running_client(tmp_path, admin_token=None, docs_enabled=True) as client:
        assert client.get("/docs").status_code == 200
        schema = client.get("/openapi.json").json()
        assert schema["info"]["title"]
        assert "/api/v1/rooms" in schema["paths"]


# --------------------------------------------------------------------------- #
# 鉴权
# --------------------------------------------------------------------------- #
def test_admin_page_is_served(tmp_path: Path) -> None:
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


def test_admin_logo_absent_without_admin_token(tmp_path: Path) -> None:
    with running_client(tmp_path, admin_token=None) as client:
        assert client.get("/admin/logo.png").status_code == 404


def test_admin_api_rejects_missing_or_wrong_token(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        missing = client.get("/api/v1/admin/overview")
        assert missing.status_code == 401
        assert missing.json()["code"] == "bad_admin_token"

        wrong = client.get("/api/v1/admin/overview", headers=admin_headers("nope"))
        assert wrong.status_code == 401

        ok = client.get("/api/v1/admin/overview", headers=admin_headers())
        assert ok.status_code == 200


# --------------------------------------------------------------------------- #
# 概览与注册开关
# --------------------------------------------------------------------------- #
def test_overview_reports_state(tmp_path: Path) -> None:
    with running_client(tmp_path, allow_registration=False) as client:
        # 注册关闭，只能由管理端建号
        client.post(
            "/api/v1/admin/users",
            json={"username": "alice", "password": PASSWORD},
            headers=admin_headers(),
        )
        token = client.post(
            "/api/v1/auth/login", json={"username": "alice", "password": PASSWORD}
        ).json()["accessToken"]
        create_room(client, token)

        body = client.get("/api/v1/admin/overview", headers=admin_headers()).json()
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
        blocked = client.post(
            "/api/v1/auth/register", json={"username": "alice", "password": PASSWORD}
        )
        assert blocked.status_code == 403

        opened = client.post(
            "/api/v1/admin/registration", json={"allow": True}, headers=admin_headers()
        )
        assert opened.status_code == 200
        assert opened.json()["allowRegistration"] is True

        created = client.post(
            "/api/v1/auth/register", json={"username": "alice", "password": PASSWORD}
        )
        assert created.status_code == 201

        closed = client.post(
            "/api/v1/admin/registration", json={"allow": False}, headers=admin_headers()
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
        created = client.post(
            "/api/v1/admin/users",
            json={"username": "alice", "password": PASSWORD, "displayName": "小明"},
            headers=admin_headers(),
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
            headers=admin_headers(),
        )
        assert duplicate.status_code == 409
        assert duplicate.json()["code"] == "username_taken"


def test_create_user_validates_input(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        bad_name = client.post(
            "/api/v1/admin/users",
            json={"username": "a b", "password": PASSWORD},
            headers=admin_headers(),
        )
        assert bad_name.status_code == 422
        short_password = client.post(
            "/api/v1/admin/users",
            json={"username": "alice", "password": "1234"},
            headers=admin_headers(),
        )
        assert short_password.status_code == 422


def test_list_users_and_filter(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        client.post(
            "/api/v1/admin/users",
            json={"username": "alice", "password": PASSWORD, "displayName": "小明"},
            headers=admin_headers(),
        )
        client.post(
            "/api/v1/admin/users",
            json={"username": "bob", "password": PASSWORD, "displayName": "小红"},
            headers=admin_headers(),
        )

        all_users = client.get("/api/v1/admin/users", headers=admin_headers()).json()
        assert all_users["total"] == 2
        assert [item["username"] for item in all_users["items"]] == ["alice", "bob"]

        by_name = client.get(
            "/api/v1/admin/users", params={"query": "bob"}, headers=admin_headers()
        ).json()
        assert by_name["total"] == 1
        assert by_name["items"][0]["displayName"] == "小红"

        by_display = client.get(
            "/api/v1/admin/users", params={"query": "小明"}, headers=admin_headers()
        ).json()
        assert by_display["total"] == 1
        assert by_display["items"][0]["username"] == "alice"


def test_disable_user_blocks_login_and_invalidates_token(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        token, user_id = register_user(client, "alice")
        assert client.get("/api/v1/auth/me", headers=auth_headers(token)).status_code == 200

        disabled = client.patch(
            f"/api/v1/admin/users/{user_id}", json={"disabled": True}, headers=admin_headers()
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
            f"/api/v1/admin/users/{user_id}", json={"disabled": False}, headers=admin_headers()
        )
        assert enabled.json()["disabled"] is False
        assert client.post(
            "/api/v1/auth/login", json={"username": "alice", "password": PASSWORD}
        ).status_code == 200


def test_disable_kicks_live_session(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        token, user_id = register_user(client, "alice")

        with contextlib.ExitStack() as stack:
            ws = stack.enter_context(client.websocket_connect(ws_url(token)))
            assert ws.receive_json()["type"] == "hello"

            response = client.patch(
                f"/api/v1/admin/users/{user_id}",
                json={"disabled": True},
                headers=admin_headers(),
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
        token, user_id = register_user(client, "alice")
        client.patch(
            f"/api/v1/admin/users/{user_id}", json={"disabled": True}, headers=admin_headers()
        )

        with (
            pytest.raises(WebSocketDisconnect) as info,
            client.websocket_connect(ws_url(token)) as ws,
        ):
            ws.receive_json()
        assert info.value.code == 4401


def test_user_list_reports_disabled_flag(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        _, user_id = register_user(client, "alice")
        client.patch(
            f"/api/v1/admin/users/{user_id}", json={"disabled": True}, headers=admin_headers()
        )

        body = client.get("/api/v1/admin/users", headers=admin_headers()).json()
        assert body["items"][0]["disabled"] is True
        assert body["items"][0]["online"] is False


def test_delete_user_cleans_rooms_memberships_and_friendships(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
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

            deleted = client.delete(f"/api/v1/admin/users/{alice_id}", headers=admin_headers())
            assert deleted.status_code == 204

            # 房主被删，房间解散，房内其他人收到通知
            closed = ws.receive_json()
            assert closed["type"] == "room_closed"
            assert closed["reason"] == "owner_deleted"
            with pytest.raises(WebSocketDisconnect):
                ws.receive_json()

        # 令牌失效、账号消失、房间消失、好友关系清空
        assert client.get("/api/v1/auth/me", headers=auth_headers(alice_token)).status_code == 401
        users = client.get("/api/v1/admin/users", headers=admin_headers()).json()
        assert [item["username"] for item in users["items"]] == ["bob"]
        assert client.get("/api/v1/admin/rooms", headers=admin_headers()).json()["total"] == 0
        assert client.get("/api/v1/friends", headers=auth_headers(bob_token)).json()["total"] == 0
        # 其他账号不受影响
        assert client.get("/api/v1/auth/me", headers=auth_headers(bob_token)).status_code == 200


def test_update_or_delete_unknown_user_returns_404(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        assert client.patch(
            "/api/v1/admin/users/999", json={"disabled": True}, headers=admin_headers()
        ).status_code == 404
        assert client.delete("/api/v1/admin/users/999", headers=admin_headers()).status_code == 404


# --------------------------------------------------------------------------- #
# 房间
# --------------------------------------------------------------------------- #
def test_admin_sees_private_rooms(client_rooms: tuple[TestClient, str, str]) -> None:
    client, public_id, private_id = client_rooms
    admin = client.get("/api/v1/admin/rooms", headers=admin_headers()).json()
    ids = {item["roomId"] for item in admin["items"]}
    assert ids == {public_id, private_id}
    assert admin["total"] == 2

    # 普通接口只看得到公开房间
    assert {item["roomId"] for item in client.get("/api/v1/rooms").json()["items"]} == {public_id}


def test_kick_member_broadcasts_and_disconnects(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        alice_token, _ = register_user(client, "alice")
        bob_token, _ = register_user(client, "bob")
        room_id = create_room(client, alice_token)["roomId"]

        with contextlib.ExitStack() as stack:
            ws_a, _ = _join_room(client, stack, alice_token, room_id)
            ws_b, hello_b = _join_room(client, stack, bob_token, room_id)
            assert ws_a.receive_json()["type"] == "member_joined"

            members = client.get(
                f"/api/v1/admin/rooms/{room_id}/members", headers=admin_headers()
            ).json()
            assert members["total"] == 2

            kicked = client.post(
                f"/api/v1/admin/rooms/{room_id}/kick",
                json={"peerId": hello_b["peerId"]},
                headers=admin_headers(),
            )
            assert kicked.status_code == 200

            assert ws_b.receive_json()["type"] == "kicked"
            left = ws_a.receive_json()
            assert left["type"] == "member_left"
            assert left["peerId"] == hello_b["peerId"]
            with pytest.raises(WebSocketDisconnect):
                ws_b.receive_json()

            remaining = client.get(
                f"/api/v1/admin/rooms/{room_id}/members", headers=admin_headers()
            ).json()
            assert [m["username"] for m in remaining["items"]] == ["alice"]


def test_kick_unknown_peer_returns_404(client_rooms: tuple[TestClient, str, str]) -> None:
    client, _public_id, private_id = client_rooms
    unknown = client.post(
        f"/api/v1/admin/rooms/{private_id}/kick",
        json={"peerId": "deadbeef"},
        headers=admin_headers(),
    )
    assert unknown.status_code == 404
    assert unknown.json()["code"] == "peer_not_found"


def test_admin_can_delete_any_room(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        alice_token, _ = register_user(client, "alice")
        bob_token, _ = register_user(client, "bob")
        room_id = create_room(client, alice_token, name="别人的房间")["roomId"]

        with contextlib.ExitStack() as stack:
            ws_a, _ = _join_room(client, stack, alice_token, room_id)
            ws_b, _ = _join_room(client, stack, bob_token, room_id)
            assert ws_a.receive_json()["type"] == "member_joined"

            deleted = client.delete(
                f"/api/v1/admin/rooms/{room_id}", headers=admin_headers()
            )
            assert deleted.status_code == 204

            for socket in (ws_a, ws_b):
                closed = socket.receive_json()
                assert closed["type"] == "room_closed"
                assert closed["reason"] == "closed_by_admin"

        assert client.get(f"/api/v1/rooms/{room_id}").status_code == 404
        assert client.get("/api/v1/admin/rooms", headers=admin_headers()).json()["total"] == 0


def test_admin_delete_missing_room(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        response = client.delete("/api/v1/admin/rooms/ZZZZZZ", headers=admin_headers())
        assert response.status_code == 404
        assert response.json()["code"] == "room_not_found"


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
