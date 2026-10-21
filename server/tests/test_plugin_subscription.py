"""音乐插件订阅：存储层 + 客户端接口 + 管理接口。

服务器只保存订阅 URL（客户端自己下载安装 MusicFree 插件），
所以这里要覆盖四条线：存得下、读得回（含损坏文件）、校验得住、鉴权得住。
"""

from __future__ import annotations

import json
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.core.errors import ValidationError
from app.main import create_app
from app.services.plugin_subscription import (
    MAX_SUBSCRIPTIONS,
    MAX_URL_LENGTH,
    PluginSubscriptionStore,
    subscription_hash,
)
from tests.conftest import admin_login, auth_headers, make_settings, register_user

#: 客户端读取接口
CLIENT_PATH = "/api/v1/music/plugin-subscription"
#: 管理接口
ADMIN_PATH = "/api/v1/admin/music/plugin-subscription"

URLS = [
    "https://example.com/musicfree/pop.json",
    "https://example.com/musicfree/rock.js",
]


def admin_headers(client: TestClient) -> dict[str, str]:
    """管理接口要的是管理员登录态：先设密码再登录（见 tests.conftest.admin_login）。"""
    return admin_login(client)


@contextmanager
def running_client(tmp_path: Path) -> Iterator[TestClient]:
    app = create_app(make_settings(tmp_path))
    with TestClient(app) as client:
        yield client


def _store(tmp_path: Path) -> PluginSubscriptionStore:
    return PluginSubscriptionStore(tmp_path / "data")


# --------------------------------------------------------------------------- #
# 存储层
# --------------------------------------------------------------------------- #
async def test_read_write_roundtrip(tmp_path: Path) -> None:
    store = _store(tmp_path)

    assert await store.read() == []  # 还没有文件
    assert await store.write(URLS) == URLS
    assert await store.read() == URLS

    # 落盘格式就是约定的 {"urls": [...]}
    payload = json.loads((tmp_path / "data" / "plugin-subscription.json").read_text("utf-8"))
    assert payload == {"urls": URLS}


async def test_new_store_instance_sees_saved_urls(tmp_path: Path) -> None:
    """重启性：换一个 store 实例（等价于重启进程）仍然读得到。"""
    await _store(tmp_path).write(URLS)
    assert await PluginSubscriptionStore(tmp_path / "data").read() == URLS


@pytest.mark.parametrize(
    "content",
    [
        "{ 这不是 JSON",
        "",
        "[]",
        '{"urls": "https://example.com/a.json"}',
        '{"urls": [1, 2, 3]}',
    ],
)
async def test_corrupt_file_reads_as_empty(tmp_path: Path, content: str) -> None:
    store = _store(tmp_path)
    store.path.parent.mkdir(parents=True, exist_ok=True)
    store.path.write_text(content, encoding="utf-8")

    assert await store.read() == []


async def test_write_dedupes_and_keeps_order(tmp_path: Path) -> None:
    store = _store(tmp_path)
    saved = await store.write([URLS[0], URLS[1], URLS[0], f"  {URLS[1]}  "])

    assert saved == URLS
    assert await store.read() == URLS


async def test_write_accepts_query_and_fragment(tmp_path: Path) -> None:
    store = _store(tmp_path)
    urls = ["https://example.com/a.json?t=1", "https://example.com/b.js#v2"]

    assert await store.write(urls) == urls


@pytest.mark.parametrize(
    "bad",
    [
        "a.json",  # 不是绝对地址
        "example.com/a.json",  # 没有协议
        "ftp://example.com/a.json",  # 协议不对
        "https://example.com/a.txt",  # 后缀不对
        "https://example.com/a",  # 没有后缀
        "https://example.com/",  # 没有后缀
        "https://",  # 没有主机
        "",  # 空串
        "   ",  # 只有空白
    ],
)
async def test_write_rejects_invalid_urls(tmp_path: Path, bad: str) -> None:
    store = _store(tmp_path)
    with pytest.raises(ValidationError) as info:
        await store.write([URLS[0], bad])

    assert info.value.code == "plugin_subscription_invalid"
    assert info.value.message  # 中文说明：第几条、为什么
    assert "第 2 条" in info.value.message
    # 校验失败不能落盘
    assert await store.read() == []


async def test_write_rejects_too_long_url(tmp_path: Path) -> None:
    too_long = "https://example.com/" + "a" * MAX_URL_LENGTH + ".json"
    assert len(too_long) > MAX_URL_LENGTH

    with pytest.raises(ValidationError) as info:
        await _store(tmp_path).write([too_long])
    assert info.value.code == "plugin_subscription_invalid"


async def test_write_accepts_url_at_length_limit(tmp_path: Path) -> None:
    head, tail = "https://example.com/", ".json"
    url = head + "a" * (MAX_URL_LENGTH - len(head) - len(tail)) + tail
    assert len(url) == MAX_URL_LENGTH

    assert await _store(tmp_path).write([url]) == [url]


async def test_write_rejects_more_than_max_subscriptions(tmp_path: Path) -> None:
    urls = [f"https://example.com/{index}.json" for index in range(MAX_SUBSCRIPTIONS + 1)]

    with pytest.raises(ValidationError) as info:
        await _store(tmp_path).write(urls)
    assert info.value.code == "plugin_subscription_invalid"
    assert str(MAX_SUBSCRIPTIONS) in info.value.message


async def test_write_accepts_exactly_max_subscriptions(tmp_path: Path) -> None:
    urls = [f"https://example.com/{index}.json" for index in range(MAX_SUBSCRIPTIONS)]
    assert await _store(tmp_path).write(urls) == urls


# --------------------------------------------------------------------------- #
# hash
# --------------------------------------------------------------------------- #
def test_hash_is_stable_and_sensitive_to_changes() -> None:
    empty = subscription_hash([])
    assert empty.startswith("sha256:")
    assert empty == subscription_hash([])  # 空列表也有稳定值
    assert subscription_hash(URLS) == subscription_hash(list(URLS))
    assert subscription_hash(URLS) != subscription_hash(URLS[:1])
    assert subscription_hash(URLS) != subscription_hash(list(reversed(URLS)))


# --------------------------------------------------------------------------- #
# 客户端接口（登录后可用）
# --------------------------------------------------------------------------- #
def test_client_endpoint_requires_login(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        response = client.get(CLIENT_PATH)
        assert response.status_code == 401

        token, _ = register_user(client, "alice")
        assert client.get(CLIENT_PATH, headers=auth_headers(token)).status_code == 200


def test_client_endpoint_empty_configuration(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        token, _ = register_user(client, "alice")
        body = client.get(CLIENT_PATH, headers=auth_headers(token)).json()

        assert body == {"urls": [], "hash": subscription_hash([])}


def test_client_endpoint_returns_saved_urls_and_stable_hash(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        token, _ = register_user(client, "alice")
        headers = auth_headers(token)

        saved = client.put(ADMIN_PATH, json={"urls": URLS}, headers=admin_headers(client))
        assert saved.status_code == 200
        assert saved.json() == {"urls": URLS}

        first = client.get(CLIENT_PATH, headers=headers).json()
        assert first == {"urls": URLS, "hash": subscription_hash(URLS)}
        # 同一个列表反复取，hash 必须稳定（客户端据此判断要不要重新拉插件）
        assert client.get(CLIENT_PATH, headers=headers).json() == first

        # 列表变了，hash 跟着变
        client.put(ADMIN_PATH, json={"urls": URLS[:1]}, headers=admin_headers(client))
        changed = client.get(CLIENT_PATH, headers=headers).json()
        assert changed["urls"] == URLS[:1]
        assert changed["hash"] == subscription_hash(URLS[:1])
        assert changed["hash"] != first["hash"]


# --------------------------------------------------------------------------- #
# 管理接口
# --------------------------------------------------------------------------- #
def test_admin_endpoints_need_admin_session(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        assert client.get(ADMIN_PATH).status_code == 401
        assert client.put(ADMIN_PATH, json={"urls": []}).status_code == 401
        assert (
            client.put(ADMIN_PATH, json={"urls": []}, headers={"Authorization": "Bearer nope"}).status_code
            == 401
        )

        # 普通登录用户（不是管理员）同样进不来：管理鉴权只看管理员登录态
        token, _ = register_user(client, "alice")
        assert client.get(ADMIN_PATH, headers=auth_headers(token)).status_code == 401
        assert (
            client.put(ADMIN_PATH, json={"urls": []}, headers=auth_headers(token)).status_code
            == 401
        )


def test_admin_endpoints_work_without_any_token_config(tmp_path: Path) -> None:
    """管理台常开：不配任何管理令牌也能用（登录一次即可）。"""
    with running_client(tmp_path) as client:
        headers = admin_headers(client)
        assert client.put(ADMIN_PATH, json={"urls": URLS}, headers=headers).status_code == 200
        assert client.get(ADMIN_PATH, headers=headers).json() == {"urls": URLS}


def test_admin_get_returns_empty_before_configured(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        body = client.get(ADMIN_PATH, headers=admin_headers(client)).json()
        assert body == {"urls": []}


def test_admin_put_then_get_is_consistent(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        saved = client.put(ADMIN_PATH, json={"urls": URLS}, headers=admin_headers(client))
        assert saved.status_code == 200
        assert saved.json() == {"urls": URLS}

        assert client.get(ADMIN_PATH, headers=admin_headers(client)).json() == {"urls": URLS}

        # 顺序被保留、空列表可以清空
        reversed_urls = list(reversed(URLS))
        assert client.put(
            ADMIN_PATH, json={"urls": reversed_urls}, headers=admin_headers(client)
        ).json() == {"urls": reversed_urls}
        assert client.put(ADMIN_PATH, json={"urls": []}, headers=admin_headers(client)).json() == {
            "urls": []
        }


@pytest.mark.parametrize(
    "bad",
    [
        "https://example.com/plugin.txt",
        "not-a-url",
        "ftp://example.com/plugin.json",
    ],
)
def test_admin_put_rejects_invalid_url(tmp_path: Path, bad: str) -> None:
    with running_client(tmp_path) as client:
        response = client.put(ADMIN_PATH, json={"urls": [bad]}, headers=admin_headers(client))

        assert 400 <= response.status_code < 500
        body = response.json()
        assert body["code"] == "plugin_subscription_invalid"
        assert body["message"]
        # 校验失败不能把已有配置改坏
        assert client.get(ADMIN_PATH, headers=admin_headers(client)).json() == {"urls": []}


def test_admin_put_rejects_too_many_urls(tmp_path: Path) -> None:
    urls = [f"https://example.com/{index}.json" for index in range(MAX_SUBSCRIPTIONS + 1)]
    with running_client(tmp_path) as client:
        response = client.put(ADMIN_PATH, json={"urls": urls}, headers=admin_headers(client))

        assert 400 <= response.status_code < 500
        assert response.json()["code"] == "plugin_subscription_invalid"


def test_subscription_survives_restart(tmp_path: Path) -> None:
    """配置落盘：换一个应用实例（等价于重启进程）仍然读得到。"""
    with running_client(tmp_path) as client:
        client.put(ADMIN_PATH, json={"urls": URLS}, headers=admin_headers(client))

    with running_client(tmp_path) as client:
        assert client.get(ADMIN_PATH, headers=admin_headers(client)).json() == {"urls": URLS}
