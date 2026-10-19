"""信令 WebSocket 端到端测试。

注意 TestClient 的会话生命周期：``WebSocketTestSession.__exit__`` 会先投递
``websocket.disconnect``，紧接着 cancel 掉应用任务。因此所有用例都必须通过
``connect()`` 上下文管理器（单次 ``__enter__``）使用连接，并依赖端点里
``anyio.CancelScope(shield=True)`` 保护的掉线收尾。
"""

from collections.abc import Iterator
from contextlib import contextmanager

import pytest
from fastapi.testclient import TestClient
from starlette.testclient import WebSocketTestSession
from starlette.websockets import WebSocketDisconnect

from tests.conftest import auth_headers, create_room, register_user, ws_url


@contextmanager
def connect(
    client: TestClient, token: str
) -> Iterator[tuple[WebSocketTestSession, dict]]:
    """建立一条已鉴权的信令连接，并消费掉服务器下发的 hello。"""
    with client.websocket_connect(ws_url(token)) as ws:
        hello = ws.receive_json()
        assert hello["type"] == "hello", hello
        yield ws, hello


def _join(ws: WebSocketTestSession, room_id: str, password: str | None = None) -> dict:
    payload: dict = {"type": "join_room", "roomId": room_id}
    if password is not None:
        payload["password"] = password
    ws.send_json(payload)
    return ws.receive_json()


def _joined(ws: WebSocketTestSession, room_id: str, password: str | None = None) -> dict:
    state = _join(ws, room_id, password)
    assert state["type"] == "room_state", state
    return state


def test_hello_describes_session_and_server(client: TestClient) -> None:
    token, user_id = register_user(client, "alice")
    with connect(client, token) as (_, hello):
        assert hello["v"] == 1
        assert len(hello["peerId"]) == 8
        assert hello["protocolVersion"] == 1
        assert hello["iceServers"] == ["stun:test.local:3478"]
        assert hello["heartbeatInterval"] == 30
        assert hello["server"]["name"]
        assert hello["user"] == {
            "id": user_id,
            "username": "alice",
            "displayName": "alice",
            "avatar": None,
        }


def test_unauthorized_connection_is_closed_with_4401(client: TestClient) -> None:
    with (
        pytest.raises(WebSocketDisconnect) as info,
        client.websocket_connect("/ws?token=not-a-token") as ws,
    ):
        ws.receive_json()
    assert info.value.code == 4401


def test_ping_pong(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    with connect(client, token) as (ws, _):
        ws.send_json({"type": "ping", "t": 123.5})
        pong = ws.receive_json()
        assert pong["type"] == "pong"
        assert pong["t"] == 123.5
        # 点歌同步需要：pong 里带服务器时钟，客户端据此做 SNTP 式偏移估计
        assert isinstance(pong["serverTimeMs"], int)


def test_join_room_broadcasts_member_joined(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    room = create_room(client, alice, capacity=5)
    room_id = room["roomId"]

    with connect(client, alice) as (ws_a, hello_a):
        state_a = _joined(ws_a, room_id)
        assert state_a["room"]["roomId"] == room_id
        assert state_a["room"]["memberCount"] == 1
        assert state_a["selfPeerId"] == hello_a["peerId"]
        assert [member["username"] for member in state_a["members"]] == ["alice"]

        with connect(client, bob) as (ws_b, hello_b):
            state_b = _joined(ws_b, room_id)
            assert state_b["room"]["memberCount"] == 2
            assert {m["peerId"] for m in state_b["members"]} == {
                hello_a["peerId"],
                hello_b["peerId"],
            }

            joined = ws_a.receive_json()
            assert joined["type"] == "member_joined"
            assert joined["member"]["peerId"] == hello_b["peerId"]
            assert joined["member"]["username"] == "bob"
            assert joined["member"]["muted"] is False
            assert joined["member"]["sharing"] is False
            assert joined["member"]["speaking"] is False

            # REST 侧看到的成员与房间列表计数都来自同一份实时状态
            assert client.get(f"/api/v1/rooms/{room_id}/members").json()["total"] == 2
            listing = client.get("/api/v1/rooms").json()
            assert listing["items"][0]["memberCount"] == 2
            assert listing["items"][0]["online"] is True


def test_membership_is_recorded_before_join_is_acknowledged(client: TestClient) -> None:
    """收到 room_state 的那一刻，进房历史必须已经落库。

    客户端进房成功后往往会立刻刷新「我的房间」，顺序反了那次刷新会查不到这个房间
    （用户看到的就是「刚进的房间没出现」）。
    """
    token, _ = register_user(client, "alice")
    room = create_room(client, token, name="私密房", is_public=False)

    with client.websocket_connect(ws_url(token)) as ws:
        assert ws.receive_json()["type"] == "hello"
        ws.send_json({"type": "join_room", "roomId": room["roomId"]})
        assert ws.receive_json()["type"] == "room_state"

        mine = client.get("/api/v1/rooms?scope=mine", headers=auth_headers(token)).json()
        assert [item["roomId"] for item in mine["items"]] == [room["roomId"]]
        # 私有房间不会出现在公开列表里，只能靠「我的房间」找到
        assert client.get("/api/v1/rooms").json()["total"] == 0


def test_member_state_is_broadcast_and_visible_in_snapshot(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    room_id = create_room(client, alice)["roomId"]

    with connect(client, alice) as (ws_a, _):
        _joined(ws_a, room_id)
        with connect(client, bob) as (ws_b, hello_b):
            _joined(ws_b, room_id)
            assert ws_a.receive_json()["type"] == "member_joined"

            ws_b.send_json(
                {"type": "member_state", "muted": True, "sharing": True, "speaking": True}
            )
            changed = ws_a.receive_json()
            assert changed == {
                "v": 1,
                "type": "member_state_changed",
                "peerId": hello_b["peerId"],
                "patch": {"muted": True, "sharing": True, "speaking": True},
            }

            snapshot = client.get(f"/api/v1/rooms/{room_id}/members").json()
            bob_state = next(m for m in snapshot["items"] if m["peerId"] == hello_b["peerId"])
            assert bob_state["muted"] is True
            assert bob_state["sharing"] is True
            assert bob_state["speaking"] is True

            # 值未变化时不广播（用 ping/pong 确认服务端仍在正常处理消息）
            ws_b.send_json({"type": "member_state", "muted": True})
            ws_b.send_json({"type": "ping", "t": 1})
            assert ws_b.receive_json()["type"] == "pong"


def test_offer_answer_candidate_are_relayed_with_src(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    room_id = create_room(client, alice)["roomId"]

    with connect(client, alice) as (ws_a, hello_a):
        _joined(ws_a, room_id)
        with connect(client, bob) as (ws_b, hello_b):
            _joined(ws_b, room_id)
            assert ws_a.receive_json()["type"] == "member_joined"

            ws_a.send_json({"type": "offer", "dst": hello_b["peerId"], "sdp": "v=0-offer"})
            assert ws_b.receive_json() == {
                "v": 1,
                "type": "offer",
                "src": hello_a["peerId"],
                "sdp": "v=0-offer",
            }

            ws_b.send_json({"type": "answer", "dst": hello_a["peerId"], "sdp": "v=0-answer"})
            assert ws_a.receive_json()["sdp"] == "v=0-answer"

            candidate = {
                "candidate": "candidate:1 1 UDP 2122260223 192.168.1.10 50000 typ host",
                "sdpMid": "0",
                "sdpMLineIndex": 0,
                "usernameFragment": "abcd",
            }
            ws_a.send_json({"type": "candidate", "dst": hello_b["peerId"], "candidate": candidate})
            relayed = ws_b.receive_json()
            assert relayed["type"] == "candidate"
            assert relayed["src"] == hello_a["peerId"]
            assert relayed["candidate"] == candidate
            assert relayed["endOfCandidates"] is False

            ws_a.send_json({"type": "candidate", "dst": hello_b["peerId"], "candidate": None})
            end = ws_b.receive_json()
            assert end["candidate"] is None
            assert end["endOfCandidates"] is True


def test_relay_to_unknown_peer_reports_peer_unavailable(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    room_id = create_room(client, alice)["roomId"]
    with connect(client, alice) as (ws, _):
        _joined(ws, room_id)
        ws.send_json({"type": "offer", "dst": "deadbeef", "sdp": "v=0"})
        error = ws.receive_json()
        assert error["code"] == "peer_unavailable"
        assert error["ref"] == "deadbeef"


def test_invalid_and_out_of_room_messages(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    locked_room = create_room(client, alice, name="加密房", password="room-password")
    public_room = create_room(client, alice, name="公开房")
    tiny_room = create_room(client, alice, name="两人房", capacity=2)

    with connect(client, alice) as (ws, _):
        assert _join(ws, "ZZZZZZ")["code"] == "room_not_found"
        assert _join(ws, locked_room["roomId"], "wrong")["code"] == "bad_password"
        assert _join(ws, public_room["roomId"])["type"] == "room_state"
        assert _join(ws, tiny_room["roomId"])["code"] == "already_in_room"

        ws.send_text("not json")
        assert ws.receive_json()["code"] == "invalid_message"
        ws.send_json({"type": "does_not_exist"})
        assert ws.receive_json()["code"] == "invalid_message"
        ws.send_json({"type": "join_room"})
        missing_field = ws.receive_json()
        assert missing_field["code"] == "invalid_message"
        assert "roomId" in missing_field["message"]

        # 离开房间后，状态上报与转发都应被拒绝
        ws.send_json({"type": "leave_room"})
        ws.send_json({"type": "member_state", "muted": True})
        assert ws.receive_json()["code"] == "not_in_room"
        ws.send_json({"type": "offer", "dst": "deadbeef", "sdp": "v=0"})
        assert ws.receive_json()["code"] == "not_in_room"


def test_rename_while_in_room_is_broadcast(client: TestClient) -> None:
    """房间里改昵称：REST 落库，信令侧把新名字播给同房间所有人（含自己）。"""
    alice_token, alice_id = register_user(client, "alice", display_name="小明")
    bob_token, _ = register_user(client, "bob", display_name="小红")
    room_id = create_room(client, alice_token, name="改名房")["roomId"]

    with (
        connect(client, alice_token) as (ws_a, _),
        connect(client, bob_token) as (ws_b, _),
    ):
        alice_peer = _joined(ws_a, room_id)["selfPeerId"]
        _joined(ws_b, room_id)
        assert ws_a.receive_json()["type"] == "member_joined"

        renamed = client.patch(
            "/api/v1/auth/me",
            json={"displayName": "小明改名了"},
            headers=auth_headers(alice_token),
        )
        assert renamed.status_code == 200

        for ws in (ws_a, ws_b):
            patch = ws.receive_json()
            assert patch["type"] == "member_state_changed", patch
            assert patch["peerId"] == alice_peer
            assert patch["patch"]["displayName"] == "小明改名了"

        # 后进来的人拿到的也是新名字（内存里的成员快照已经换过）
        carol_token, _ = register_user(client, "carol")
        with connect(client, carol_token) as (ws_c, _):
            state = _joined(ws_c, room_id)
            names = {member["userId"]: member["displayName"] for member in state["members"]}
            assert names[alice_id] == "小明改名了"


def test_avatar_change_while_in_room_is_broadcast(client: TestClient) -> None:
    """房间里换头像：补丁带新版本号；移除时带显式 null（客户端据此清掉图片）。"""
    alice_token, _ = register_user(client, "alice")
    bob_token, _ = register_user(client, "bob")
    room_id = create_room(client, alice_token, name="头像房")["roomId"]

    with (
        connect(client, alice_token) as (ws_a, _),
        connect(client, bob_token) as (ws_b, _),
    ):
        alice_peer = _joined(ws_a, room_id)["selfPeerId"]
        _joined(ws_b, room_id)
        assert ws_a.receive_json()["type"] == "member_joined"

        uploaded = client.post(
            "/api/v1/auth/avatar",
            files={"file": ("a.png", b"\x89PNG\r\n\x1a\nbody", "image/png")},
            headers=auth_headers(alice_token),
        )
        assert uploaded.status_code == 200
        version = uploaded.json()["avatar"]

        for ws in (ws_a, ws_b):
            patch = ws.receive_json()
            assert patch["type"] == "member_state_changed", patch
            assert patch["peerId"] == alice_peer
            assert patch["patch"]["avatar"] == version

        removed = client.delete(
            "/api/v1/auth/avatar", headers=auth_headers(alice_token)
        )
        assert removed.status_code == 200

        for ws in (ws_a, ws_b):
            patch = ws.receive_json()
            assert patch["patch"]["avatar"] is None


def test_room_full_rejects_the_extra_member(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    carol, _ = register_user(client, "carol")
    tiny_room = create_room(client, alice, name="两人房", capacity=2)["roomId"]

    with (
        connect(client, alice) as (ws_a, _),
        connect(client, bob) as (ws_b, _),
        connect(client, carol) as (ws_c, _),
    ):
        assert _join(ws_a, tiny_room)["type"] == "room_state"
        assert _join(ws_b, tiny_room)["type"] == "room_state"  # 第 2 人仍可进入
        assert ws_a.receive_json()["type"] == "member_joined"

        # 第 3 人被拒，且房间成员不变
        assert _join(ws_c, tiny_room)["code"] == "room_full"
        assert client.get(f"/api/v1/rooms/{tiny_room}/members").json()["total"] == 2


def test_leave_room_and_disconnect_broadcast_member_left(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    room_id = create_room(client, alice)["roomId"]

    with connect(client, alice) as (ws_a, _):
        _joined(ws_a, room_id)
        with connect(client, bob) as (ws_b, hello_b):
            _joined(ws_b, room_id)
            assert ws_a.receive_json()["type"] == "member_joined"

            ws_b.send_json({"type": "leave_room"})
            assert ws_a.receive_json() == {
                "v": 1,
                "type": "member_left",
                "peerId": hello_b["peerId"],
                "reason": "left",
            }

            # 重新进房，然后直接断开连接，验证掉线收尾
            _joined(ws_b, room_id)
            assert ws_a.receive_json()["type"] == "member_joined"

        # bob 的会话已退出 = 掉线；收尾被 shield 保护，这条广播一定会发出
        dropped = ws_a.receive_json()
        assert dropped["type"] == "member_left"
        assert dropped["peerId"] == hello_b["peerId"]
        assert dropped["reason"] == "disconnected"
        assert client.get(f"/api/v1/rooms/{room_id}/members").json()["total"] == 1


def test_duplicate_session_kicks_the_older_one(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")

    # 同一个账号先建一条连接，再建第二条：第一条必须被顶下线
    with (
        connect(client, alice) as (ws_first, first_hello),
        connect(client, alice) as (ws_second, second_hello),
    ):
        assert second_hello["peerId"] != first_hello["peerId"]

        kicked = ws_first.receive_json()
        assert kicked["type"] == "kicked"
        assert kicked["reason"] == "duplicate_session"
        assert kicked["code"] == "duplicate_session"
        with pytest.raises(WebSocketDisconnect):
            ws_first.receive_json()

        # 新会话不受影响
        ws_second.send_json({"type": "ping", "t": 7})
        assert ws_second.receive_json()["type"] == "pong"
        assert client.get("/api/v1/health").json()["peers"] == 1

    assert client.get("/api/v1/health").json()["peers"] == 0


def test_ws_connection_marks_user_online_for_friends(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    client.post(
        "/api/v1/friends/requests", json={"username": "bob"}, headers=auth_headers(alice)
    )
    incoming = client.get("/api/v1/friends/requests", headers=auth_headers(bob)).json()
    client.post(
        f"/api/v1/friends/requests/{incoming['items'][0]['id']}",
        json={"accept": True},
        headers=auth_headers(bob),
    )

    with connect(client, bob):
        friends = client.get("/api/v1/friends", headers=auth_headers(alice)).json()
        assert friends["items"][0]["online"] is True
        assert friends["items"][0]["user"]["online"] is True

    assert client.get("/api/v1/friends", headers=auth_headers(alice)).json()["items"][0][
        "online"
    ] is False


def test_room_closed_by_owner_disconnects_members(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    room_id = create_room(client, alice)["roomId"]

    with connect(client, alice) as (ws_a, _):
        _joined(ws_a, room_id)
        with connect(client, bob) as (ws_b, _):
            _joined(ws_b, room_id)
            assert ws_a.receive_json()["type"] == "member_joined"

            assert client.delete(
                f"/api/v1/rooms/{room_id}", headers=auth_headers(alice)
            ).status_code == 204

            for socket in (ws_a, ws_b):
                closed = socket.receive_json()
                assert closed["type"] == "room_closed"
                assert closed["reason"] == "closed"
            with pytest.raises(WebSocketDisconnect):
                ws_a.receive_json()


def test_lowering_capacity_evicts_the_last_joined_member(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    carol, _ = register_user(client, "carol")
    room_id = create_room(client, alice, capacity=5)["roomId"]

    with (
        connect(client, alice) as (ws_a, _),
        connect(client, bob) as (ws_b, _),
        connect(client, carol) as (ws_c, hello_c),
    ):
        _joined(ws_a, room_id)
        _joined(ws_b, room_id)
        assert ws_a.receive_json()["member"]["username"] == "bob"

        _joined(ws_c, room_id)
        assert ws_a.receive_json()["member"]["username"] == "carol"
        assert ws_b.receive_json()["member"]["username"] == "carol"

        client.patch(
            f"/api/v1/rooms/{room_id}", json={"capacity": 2}, headers=auth_headers(alice)
        )

        # 最后进房的 carol 被请出房间（连接保留），其余成员收到 member_left
        evicted = ws_c.receive_json()
        assert evicted["type"] == "room_closed"
        assert evicted["roomId"] == room_id
        assert evicted["reason"] == "room_capacity_changed"

        left = ws_a.receive_json()
        assert left["type"] == "member_left"
        assert left["peerId"] == hello_c["peerId"]
        assert left["reason"] == "room_capacity_changed"

        members = client.get(f"/api/v1/rooms/{room_id}/members").json()
        assert members["total"] == 2
        assert hello_c["peerId"] not in {m["peerId"] for m in members["items"]}
