"""信令 WebSocket 的错误文案多语言：``?lang=`` 选语言、缺失/非法回落中文、不泄漏。

为什么单独一个文件：HTTP 侧的协商由 ``LocaleMiddleware`` 按 ``Accept-Language`` 做，
信令这条链不经过中间件，语言来自连接参数、由端点自己压进上下文变量——两套入口，
就得两套用例，否则「HTTP 通了」会让人误以为信令也通了（正是这次要补的窟窿）。
"""

import pytest
from fastapi.testclient import TestClient

from app.core.i18n import t
from tests.conftest import register_user, ws_url


def _url(token: str, lang: str | None = None) -> str:
    """带上 ``lang`` 的信令地址；``lang=None`` 表示完全不传这个参数。"""
    return ws_url(token) if lang is None else f"{ws_url(token)}&lang={lang}"


def _join_unknown_room(client: TestClient, token: str, lang: str | None) -> dict:
    """进一个不存在的房间，取回 ``error`` 消息（文案最简单的触发路径）。"""
    with client.websocket_connect(_url(token, lang)) as ws:
        assert ws.receive_json()["type"] == "hello"
        ws.send_json({"type": "join_room", "roomId": "ZZZZZZ"})
        error = ws.receive_json()
        assert error["type"] == "error", error
        assert error["code"] == "room_not_found"
        return error


@pytest.mark.parametrize(
    ("lang", "expected"),
    [
        ("zh", "房间不存在"),
        ("en", "Room not found"),
        ("ja", "ルームが見つかりません"),
        ("ko", "룸을 찾을 수 없습니다"),
    ],
)
def test_连接参数决定错误文案语言(client: TestClient, lang: str, expected: str) -> None:
    """四种语言逐一断言原文：只跟 ``t()`` 比会漏掉「文案表改了但连接没生效」这类错。"""
    token, _ = register_user(client, "alice")
    assert _join_unknown_room(client, token, lang)["message"] == expected


def test_带日语参数时错误文案是日文(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    message = _join_unknown_room(client, token, "ja")["message"]
    assert message == "ルームが見つかりません"
    assert message != t("ws.room_not_found", locale="zh")


def test_不传语言参数时仍是中文原文(client: TestClient) -> None:
    """存量客户端不会带 ``lang``：它们看到的必须还是改动前那句中文。"""
    token, _ = register_user(client, "alice")
    assert _join_unknown_room(client, token, None)["message"] == "房间不存在"


def test_不支持的语言回落中文(client: TestClient) -> None:
    """法语客户端没有兜底文案，回落中文而不是英文（与界面语言的回落一致）。"""
    token, _ = register_user(client, "alice")
    assert _join_unknown_room(client, token, "fr")["message"] == "房间不存在"


def test_lang_写坏了也回落中文(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    assert _join_unknown_room(client, token, ";;;")["message"] == "房间不存在"


def test_locale_不会泄漏到下一条连接(client: TestClient) -> None:
    """先连一条日语，再连一条不带参数的：后者必须是中文。

    上下文变量在两条连接之间是同一份，端点不在 finally 里还原的话，后一条连接会
    继承前一条的语言——单连接用例发现不了这个问题。
    """
    token, _ = register_user(client, "alice")
    assert _join_unknown_room(client, token, "ja")["message"] == "ルームが見つかりません"
    assert _join_unknown_room(client, token, None)["message"] == "房间不存在"


def test_点歌拒绝原因同样跟随语言(client: TestClient) -> None:
    """点歌的失败原因来自 ``app.signaling.music`` 抛的 ``MusicError``，走的是另一条路径。"""
    token, _ = register_user(client, "alice")
    with client.websocket_connect(_url(token, "en")) as ws:
        assert ws.receive_json()["type"] == "hello"
        ws.send_json(
            {
                "type": "music_enqueue",
                "source": "netease",
                "songId": "1",
                "musicInfo": {"id": 1},
            }
        )
        error = ws.receive_json()
        assert error["code"] == "not_in_room"
        assert error["message"] == "You have not joined a room yet"
