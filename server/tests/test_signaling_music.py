"""房间共享点歌队列的信令端到端测试。

用真实的 WebSocket 走一遍：进房快照带队列、点歌全量广播、每人上限 / 冷却、
删除与切歌权限、清空、EOS 幂等，以及不在房间时的拒绝。
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from typing import Any

from fastapi.testclient import TestClient
from starlette.testclient import WebSocketTestSession

from tests.conftest import auth_headers, create_room, register_user, ws_url

MAX_WAIT_MESSAGES = 20


@contextmanager
def connect(client: TestClient, token: str) -> Iterator[tuple[WebSocketTestSession, dict[str, Any]]]:
    with client.websocket_connect(ws_url(token)) as ws:
        hello = ws.receive_json()
        assert hello["type"] == "hello", hello
        yield ws, hello


def _join(ws: WebSocketTestSession, room_id: str) -> dict[str, Any]:
    ws.send_json({"type": "join_room", "roomId": room_id})
    state = ws.receive_json()
    assert state["type"] == "room_state", state
    return state


def _recv(ws: WebSocketTestSession, wanted: str) -> dict[str, Any]:
    for _ in range(MAX_WAIT_MESSAGES):
        message = ws.receive_json()
        if message["type"] == wanted:
            return message
    raise AssertionError(f"没有等到 {wanted} 消息")


def _enqueue(ws: WebSocketTestSession, song_id: str, *, title: str | None = None) -> None:
    ws.send_json(
        {
            "type": "music_enqueue",
            "source": "kugou",
            "songId": song_id,
            "musicInfo": {"id": song_id, "title": title or f"歌{song_id}"},
            "title": title or f"歌{song_id}",
            "artist": "歌手",
            "durationMs": 180_000,
        }
    )


def test_hello_and_room_state_expose_music(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    room = create_room(client, token)
    with connect(client, token) as (ws, hello):
        assert isinstance(hello["serverTimeMs"], int)
        assert hello["musicEnabled"] is True
        assert hello["musicBatch"] is True

        state = _join(ws, room["roomId"])
        music = state["music"]
        assert music["revision"] == 0
        assert music["current"] is None
        assert music["queue"] == []
        assert isinstance(music["serverTimeMs"], int)


def test_enqueue_broadcasts_state_with_anchor(client: TestClient) -> None:
    alice, _ = register_user(client, "alice", display_name="阿杰")
    bob, _ = register_user(client, "bob")
    room = create_room(client, alice)

    with connect(client, alice) as (ws_a, hello_a):
        _join(ws_a, room["roomId"])
        with connect(client, bob) as (ws_b, hello_b):
            _join(ws_b, room["roomId"])
            _recv(ws_a, "member_joined")

            _enqueue(ws_a, "song-1", title="富士山下")

            for ws in (ws_a, ws_b):
                state = _recv(ws, "music_state")
                assert state["revision"] == 1
                current = state["current"]
                assert current["entryId"] == "e1"
                assert current["source"] == "kugou"
                assert current["songId"] == "song-1"
                assert current["title"] == "富士山下"
                # 广播的必须是音源原始对象，客户端各自解析直链
                assert current["musicInfo"]["id"] == "song-1"
                assert current["requestedBy"] == {
                    "peerId": hello_a["peerId"],
                    "displayName": "阿杰",
                }
                # 预滚：锚点晚于本条消息的服务器时刻，客户端据此起播
                assert current["anchorServerMs"] >= state["serverTimeMs"]
                assert current["playing"] is True
                assert state["queue"] == []

            # 第二首进队列，当前曲不变
            _enqueue(ws_b, "song-2")
            state = _recv(ws_a, "music_state")
            assert state["revision"] == 2
            assert state["current"]["entryId"] == "e1"
            assert [item["entryId"] for item in state["queue"]] == ["e2"]
            assert state["queue"][0]["requestedBy"]["peerId"] == hello_b["peerId"]


def test_enqueue_batch_accepts_whole_batch_at_once(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    room = create_room(client, alice)

    with connect(client, alice) as (ws, _):
        _join(ws, room["roomId"])
        ws.send_json(
            {
                "type": "music_enqueue_batch",
                "entries": [
                    {
                        "source": "kugou",
                        "songId": f"song-{index}",
                        "musicInfo": {"id": f"song-{index}"},
                        "title": f"歌{index}",
                        "artist": "歌手",
                        "durationMs": 180_000,
                    }
                    for index in range(3)
                ],
            }
        )

        # 一批只广播一次：当前曲是第一首，其余进队列
        state = _recv(ws, "music_state")
        assert state["revision"] == 1
        assert state["current"]["songId"] == "song-0"
        assert [item["songId"] for item in state["queue"]] == ["song-1", "song-2"]


def test_music_mode_is_room_wide(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    room = create_room(client, alice)

    with connect(client, alice) as (ws_a, _), connect(client, bob) as (ws_b, _):
        _join(ws_a, room["roomId"])
        _join(ws_b, room["roomId"])
        _recv(ws_a, "member_joined")

        # 谁都能改，而且房间级：两个人拿到的快照都变成单曲循环
        ws_b.send_json({"type": "music_mode", "mode": "repeat_one"})
        for ws in (ws_a, ws_b):
            state = _recv(ws, "music_state")
            assert state["mode"] == "repeat_one"

        # 非法模式由协议层挡掉，不会污染房间状态
        ws_b.send_json({"type": "music_mode", "mode": "nope"})
        error = _recv(ws_b, "error")
        assert error["code"] == "invalid_message"


def test_enqueue_rate_limit(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    room = create_room(client, alice)

    with connect(client, alice) as (ws, _):
        _join(ws, room["roomId"])
        _enqueue(ws, "song-1")
        _recv(ws, "music_state")

        # 同一个人的第二首会被 2 秒冷却拦下（两条消息之间远不到 2 秒）
        _enqueue(ws, "song-2")
        error = _recv(ws, "error")
        assert error["code"] == "music_rate_limited"
        assert error["ref"] == "music_enqueue"


def test_remove_and_skip_permissions(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    room = create_room(client, alice)

    with connect(client, alice) as (ws_a, _), connect(client, bob) as (ws_b, _):
        _join(ws_a, room["roomId"])
        _join(ws_b, room["roomId"])
        _recv(ws_a, "member_joined")

        _enqueue(ws_a, "song-1")
        _recv(ws_b, "music_state")

        # 不是自己点的、也不是房主：不能删
        ws_b.send_json({"type": "music_remove", "entryId": "e1"})
        error = _recv(ws_b, "error")
        assert error["code"] == "music_forbidden"

        # 不是点歌人、也不是房主：不能切
        ws_b.send_json({"type": "music_skip", "entryId": "e1"})
        error = _recv(ws_b, "error")
        assert error["code"] == "music_forbidden"

        # 房主可以切歌 → 队列空了，current 变 null
        ws_a.send_json({"type": "music_skip"})
        state = _recv(ws_b, "music_state")
        assert state["current"] is None
        assert state["queue"] == []

        # 队列空时切歌是 not_found
        ws_a.send_json({"type": "music_skip"})
        error = _recv(ws_a, "error")
        assert error["code"] == "music_not_found"


def test_clear_requires_owner(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    bob, _ = register_user(client, "bob")
    room = create_room(client, alice)

    with connect(client, alice) as (ws_a, _), connect(client, bob) as (ws_b, _):
        _join(ws_a, room["roomId"])
        _join(ws_b, room["roomId"])
        _recv(ws_a, "member_joined")

        _enqueue(ws_a, "song-1")
        _recv(ws_b, "music_state")

        ws_b.send_json({"type": "music_clear"})
        error = _recv(ws_b, "error")
        assert error["code"] == "music_forbidden"

        ws_a.send_json({"type": "music_clear"})
        state = _recv(ws_b, "music_state")
        assert state["current"] is None
        assert state["queue"] == []


def test_eos_advances_once(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    room = create_room(client, alice)

    with connect(client, alice) as (ws, _):
        _join(ws, room["roomId"])
        # 默认是列表循环（放完会重新排起来）；这条用例要看「队列空了就停」，
        # 所以先切成顺序播放，再点歌（模式会推进 revision，EOS 必须用最新那个）
        ws.send_json({"type": "music_mode", "mode": "sequential"})
        _recv(ws, "music_state")
        _enqueue(ws, "song-1")
        first = _recv(ws, "music_state")
        _enqueue(ws, "song-2")  # 会被冷却拦下，这里只用第一首
        _recv(ws, "error")

        ws.send_json(
            {"type": "music_eos", "entryId": "e1", "revision": first["revision"]}
        )
        state = _recv(ws, "music_state")
        assert state["revision"] == first["revision"] + 1
        assert state["current"] is None

        # 过期 revision 的重复上报不会再生效（幂等）
        ws.send_json(
            {"type": "music_eos", "entryId": "e1", "revision": first["revision"]}
        )
        ws.send_json({"type": "music_skip"})  # 用一次交互确认连接仍然活着
        error = _recv(ws, "error")
        assert error["code"] == "music_not_found"


def test_music_requires_room(client: TestClient) -> None:
    alice, _ = register_user(client, "alice")
    with connect(client, alice) as (ws, _):
        _enqueue(ws, "song-1")
        error = _recv(ws, "error")
        assert error["code"] == "not_in_room"
        assert error["ref"] == "music_enqueue"


def test_room_members_can_read_queue_from_api(client: TestClient) -> None:
    """队列只在信令里，REST 侧的房间列表不该因为点歌而变。"""
    alice, _ = register_user(client, "alice")
    room = create_room(client, alice)
    with connect(client, alice) as (ws, _):
        _join(ws, room["roomId"])
        _enqueue(ws, "song-1")
        _recv(ws, "music_state")

        listing = client.get("/api/v1/rooms", headers=auth_headers(alice)).json()
        assert listing["items"][0]["memberCount"] == 1
