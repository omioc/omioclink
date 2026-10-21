"""``/api/v1/music`` 现在只剩插件订阅接口。

洛雪音源脚本与音乐元数据代理（搜索 / 歌单 / 榜单 / 首页 / 专题）已经整体删除：
服务器不解析、不代理任何音乐元数据，只保存「插件订阅 URL」交给客户端。
这里既要验证订阅接口的鉴权，也要**确认那些老路由真的不存在**（404，而不是「存在但返回空」）。
"""

from __future__ import annotations

from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.services.plugin_subscription import subscription_hash
from tests.conftest import admin_login, auth_headers, make_settings, register_user

#: 本版本里必须**不存在**的音乐元数据/洛雪音源接口
REMOVED_PATHS = [
    "/api/v1/music/sources",
    "/api/v1/music/platforms",
    "/api/v1/music/search/tracks",
    "/api/v1/music/search/playlists",
    "/api/v1/music/charts",
    "/api/v1/music/charts/wy/3778678",
    "/api/v1/music/playlists",
    "/api/v1/music/playlists/wy/14271974406",
    "/api/v1/music/home",
    "/api/v1/music/topics/night",
    # 管理端「音源脚本」接口也一并不存在（含 import-file / import-url / 启停 / 删除）
    "/api/v1/admin/music-sources",
    "/api/v1/admin/music-sources/import-url",
    "/api/v1/admin/music-sources/import-file",
    "/api/v1/admin/music-sources/abc123",
]


@contextmanager
def running_client(tmp_path: Path) -> Iterator[TestClient]:
    app = create_app(make_settings(tmp_path))
    with TestClient(app) as client:
        yield client


# --------------------------------------------------------------------------- #
# 老接口必须消失
# --------------------------------------------------------------------------- #
def test_only_plugin_subscription_route_is_registered(tmp_path: Path) -> None:
    """看 OpenAPI 里登记的路径：``/api/v1/music`` 下只剩 plugin-subscription。

    用 ``app.openapi()`` 而不是遍历 ``app.routes``：这个 FastAPI 版本把
    ``include_router`` 的结果包成 ``_IncludedRouter``，扁平路径只在 schema 里齐全。
    """
    app = create_app(make_settings(tmp_path))
    paths = set(app.openapi()["paths"])

    music_paths = {path for path in paths if path.startswith("/api/v1/music")}
    assert music_paths == {"/api/v1/music/plugin-subscription"}
    # 全站带 music 的路径只有这两条：客户端读 + 管理员写。
    # 音源脚本相关的管理接口（/admin/music-sources*）一条都不该存在。
    assert {path for path in paths if "music" in path} == {
        "/api/v1/music/plugin-subscription",
        "/api/v1/admin/music/plugin-subscription",
    }


@pytest.mark.parametrize("path", REMOVED_PATHS)
def test_removed_music_endpoints_return_404(tmp_path: Path, path: str) -> None:
    with running_client(tmp_path) as client:
        token, _ = register_user(client, "alice")
        response = client.get(path, headers=auth_headers(token))

        assert response.status_code == 404, f"{path} 竟然还存在：{response.status_code}"


def test_removed_music_endpoints_are_not_writable(tmp_path: Path) -> None:
    """老的管理接口即使带正确令牌也必须是 404（路由不存在，不是鉴权失败）。"""
    with running_client(tmp_path) as client:
        for method in ("post", "patch", "delete"):
            response = getattr(client, method)(
                "/api/v1/admin/music-sources/abc123",
                headers=admin_login(client),
            )
            assert response.status_code == 404


# --------------------------------------------------------------------------- #
# 订阅接口
# --------------------------------------------------------------------------- #
def test_plugin_subscription_requires_auth(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        assert client.get("/api/v1/music/plugin-subscription").status_code == 401
        token, _ = register_user(client, "alice")
        ok = client.get("/api/v1/music/plugin-subscription", headers=auth_headers(token))
        assert ok.status_code == 200
        assert ok.json() == {"urls": [], "hash": subscription_hash([])}


def test_plugin_subscription_reflects_admin_configuration(tmp_path: Path) -> None:
    urls = ["https://example.com/musicfree/plugin.json"]
    with running_client(tmp_path) as client:
        token, _ = register_user(client, "alice")
        saved = client.put(
            "/api/v1/admin/music/plugin-subscription",
            json={"urls": urls},
            headers=admin_login(client),
        )
        assert saved.status_code == 200

        body = client.get(
            "/api/v1/music/plugin-subscription", headers=auth_headers(token)
        ).json()
        assert body == {"urls": urls, "hash": subscription_hash(urls)}


# --------------------------------------------------------------------------- #
# /server/info 的能力位（客户端据此显示点歌台入口）
# --------------------------------------------------------------------------- #
def test_server_info_reports_music_enabled(tmp_path: Path) -> None:
    with running_client(tmp_path) as client:
        assert client.get("/api/v1/server/info").json()["musicEnabled"] is True


def test_music_can_be_disabled(tmp_path: Path) -> None:
    settings = make_settings(tmp_path).model_copy(update={"music_enabled": False})
    app = create_app(settings)
    with TestClient(app) as client:
        assert client.get("/api/v1/server/info").json()["musicEnabled"] is False
