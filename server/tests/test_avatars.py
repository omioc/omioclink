"""头像上传 / 读取 / 移除。

这里的「图片」只在**文件头**层面合法——服务端只做类型嗅探，不解码图片，
所以不需要真实可渲染的像素数据。
"""

import re
from pathlib import Path
from typing import Any

import pytest
from fastapi.testclient import TestClient

from app.core.config import Settings
from app.main import create_app
from app.services.avatars import avatar_version, sniff_image_type
from tests.conftest import auth_headers, make_settings, register_user

PNG = b"\x89PNG\r\n\x1a\n" + b"fake-png-body"
JPEG = b"\xff\xd8\xff\xe0" + b"fake-jpeg-body"
GIF = b"GIF89a" + b"fake-gif-body"
WEBP = b"RIFF\x00\x00\x00\x00WEBP" + b"fake-webp-body"

VERSION_PATTERN = re.compile(r"^[0-9a-f]{16}$")


def _upload(client: TestClient, token: str, data: bytes, *, name: str = "a.png") -> Any:
    # 返回的是 starlette 测试客户端包装的响应对象（内部是 httpx2），这里不引它的类型
    return client.post(
        "/api/v1/auth/avatar",
        files={"file": (name, data, "image/png")},
        headers=auth_headers(token),
    )


def test_upload_returns_version_and_image_is_served(client: TestClient) -> None:
    token, user_id = register_user(client, "alice")

    uploaded = _upload(client, token, PNG)
    assert uploaded.status_code == 200, uploaded.text
    version = uploaded.json()["avatar"]
    assert VERSION_PATTERN.match(version), version
    assert version == avatar_version(PNG)

    fetched = client.get(
        f"/api/v1/avatars/{user_id}",
        params={"v": version},
        headers=auth_headers(token),
    )
    assert fetched.status_code == 200
    assert fetched.content == PNG
    assert fetched.headers["content-type"] == "image/png"
    # 类型已按文件头确认，禁止浏览器再嗅探
    assert fetched.headers["x-content-type-options"] == "nosniff"
    assert "immutable" in fetched.headers["cache-control"]


@pytest.mark.parametrize(
    ("data", "expected"),
    [(PNG, "image/png"), (JPEG, "image/jpeg"), (GIF, "image/gif"), (WEBP, "image/webp")],
)
def test_supported_formats(client: TestClient, data: bytes, expected: str) -> None:
    token, user_id = register_user(client, "alice")
    version = _upload(client, token, data).json()["avatar"]

    fetched = client.get(
        f"/api/v1/avatars/{user_id}",
        params={"v": version},
        headers=auth_headers(token),
    )
    assert fetched.status_code == 200
    assert fetched.headers["content-type"] == expected


def test_rejects_content_that_is_not_an_image(client: TestClient) -> None:
    token, _ = register_user(client, "alice")

    # 关键：文件名与 Content-Type 都声称是 png，但内容不是 —— 只认文件头
    response = _upload(client, token, b"<html><script>x</script></html>")
    assert response.status_code == 422
    assert response.json()["code"] == "unsupported_image"

    # SVG 可以内嵌脚本，明确不接受
    svg = b'<svg xmlns="http://www.w3.org/2000/svg"><script>x()</script></svg>'
    assert _upload(client, token, svg, name="a.svg").status_code == 422


def test_rejects_empty_body(client: TestClient) -> None:
    token, _ = register_user(client, "alice")
    response = _upload(client, token, b"")
    assert response.status_code == 422
    assert response.json()["code"] == "empty_avatar"


def test_rejects_oversize(tmp_path: Path) -> None:
    settings: Settings = make_settings(tmp_path).model_copy(
        update={"avatar_max_bytes": 8192}
    )
    with TestClient(create_app(settings)) as client:
        token, _ = register_user(client, "alice")
        response = _upload(client, token, PNG + b"\x00" * 9000)
        assert response.status_code == 413
        assert response.json()["code"] == "avatar_too_large"


def test_reupload_replaces_the_old_file(
    client: TestClient, settings: Settings
) -> None:
    token, user_id = register_user(client, "alice")
    first = _upload(client, token, PNG).json()["avatar"]
    second = _upload(client, token, PNG + b"v2").json()["avatar"]
    assert first != second

    # 旧版本立刻取不到（文件已删），新版本可用
    assert (
        client.get(
            f"/api/v1/avatars/{user_id}",
            params={"v": first},
            headers=auth_headers(token),
        ).status_code
        == 404
    )
    assert (
        client.get(
            f"/api/v1/avatars/{user_id}",
            params={"v": second},
            headers=auth_headers(token),
        ).status_code
        == 200
    )

    # 每个用户同时只会留一份文件
    files = list((settings.data_dir / "avatars").glob(f"{user_id}-*"))
    assert len(files) == 1, files

    # 内容寻址：把第一张再传回去，版本号回到 first
    assert _upload(client, token, PNG).json()["avatar"] == first


def test_delete_avatar(client: TestClient) -> None:
    token, user_id = register_user(client, "alice")
    version = _upload(client, token, PNG).json()["avatar"]

    removed = client.delete("/api/v1/auth/avatar", headers=auth_headers(token))
    assert removed.status_code == 200
    assert removed.json()["avatar"] is None

    assert (
        client.get(
            f"/api/v1/avatars/{user_id}",
            params={"v": version},
            headers=auth_headers(token),
        ).status_code
        == 404
    )
    assert client.get("/api/v1/auth/me", headers=auth_headers(token)).json()["avatar"] is None


def test_avatar_read_requires_login_and_a_valid_version(client: TestClient) -> None:
    token, user_id = register_user(client, "alice")
    version = _upload(client, token, PNG).json()["avatar"]

    assert (
        client.get(
            f"/api/v1/avatars/{user_id}", params={"v": version}
        ).status_code
        == 401
    )

    # 版本号会被拼进文件路径：非法格式一律当不存在，绝不落到 glob/穿越上
    for bad in ("../../etc/passwd", "*", "1-2", "", "A" * 16, version.upper() + "x"):
        response = client.get(
            f"/api/v1/avatars/{user_id}",
            params={"v": bad},
            headers=auth_headers(token),
        )
        assert response.status_code == 404, bad
        assert response.json()["code"] == "avatar_not_found"


def test_version_token_does_not_leak_the_file_path(
    client: TestClient, settings: Settings
) -> None:
    token, user_id = register_user(client, "alice")
    version = _upload(client, token, PNG).json()["avatar"]

    # 版本号就是内容哈希前缀，文件按 <user>-<version>.<ext> 落盘
    assert (settings.data_dir / "avatars" / f"{user_id}-{version}.png").is_file()


def test_friend_list_carries_avatar_version(client: TestClient) -> None:
    alice_token, _ = register_user(client, "alice")
    bob_token, bob_id = register_user(client, "bob")
    version = _upload(client, bob_token, PNG).json()["avatar"]

    client.post(
        "/api/v1/friends/requests",
        json={"username": "bob"},
        headers=auth_headers(alice_token),
    )
    client.post(
        "/api/v1/friends/requests",
        json={"username": "alice"},
        headers=auth_headers(bob_token),
    )

    friends = client.get("/api/v1/friends", headers=auth_headers(alice_token)).json()
    bob = next(item for item in friends["items"] if item["user"]["id"] == bob_id)
    assert bob["user"]["avatar"] == version


def test_sniff_image_type_ignores_extension() -> None:
    assert sniff_image_type(PNG) == "png"
    assert sniff_image_type(JPEG) == "jpeg"
    assert sniff_image_type(b"not an image at all") is None
    assert sniff_image_type(b"") is None
    # RIFF 但不是 WEBP（例如 wav）
    assert sniff_image_type(b"RIFF\x00\x00\x00\x00WAVE") is None
