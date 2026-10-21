"""JWT 密钥「用户不填就自动生成并持久化」的测试。

``OMIOCLINK_JWT_SECRET`` 以前是必填项（不填容器直接起不来），现在留空就由服务端
自己生成一份写进 ``<data_dir>/jwt-secret``。这里验证三件事：
生成后落盘、重启复用、用户指定的值优先。
"""

from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from app.services.server_secret import (
    JWT_SECRET_FILE_NAME,
    MIN_SECRET_BYTES,
    ServerSecretStore,
)
from tests.conftest import PASSWORD, auth_headers, make_settings

#: 没有密钥时用它当 data_dir，避免在仓库里造出 data/
DATA_DIR_NAME = "data"


def _store(tmp_path: Path) -> ServerSecretStore:
    return ServerSecretStore(tmp_path / DATA_DIR_NAME)


def test_generates_and_persists(tmp_path: Path) -> None:
    store = _store(tmp_path)
    secret = store.ensure_jwt_secret("")

    assert len(secret.encode("utf-8")) >= MIN_SECRET_BYTES
    assert store.jwt_secret_path == tmp_path / DATA_DIR_NAME / JWT_SECRET_FILE_NAME
    assert store.jwt_secret_path.read_text(encoding="utf-8").strip() == secret


def test_reuses_persisted_secret(tmp_path: Path) -> None:
    """重启（新实例）必须读回同一份密钥，否则所有已登录设备都会掉线。"""
    first = _store(tmp_path).ensure_jwt_secret(None)
    assert _store(tmp_path).ensure_jwt_secret(None) == first


@pytest.mark.parametrize("configured", ["", "   ", None])
def test_blank_configuration_counts_as_unset(tmp_path: Path, configured: str | None) -> None:
    assert _store(tmp_path).ensure_jwt_secret(configured)
    assert _store(tmp_path).jwt_secret_path.exists()


def test_configured_secret_wins_and_is_not_written(tmp_path: Path) -> None:
    store = _store(tmp_path)
    configured = "configured-secret-value-32-bytes-min"

    assert store.ensure_jwt_secret(configured) == configured
    # 用户指定了就不该往数据目录里塞文件（避免下次误读成"用户配置"）
    assert not store.jwt_secret_path.exists()


@pytest.mark.parametrize("content", ["too-short", "", "   \n"])
def test_broken_file_is_regenerated(tmp_path: Path, content: str) -> None:
    store = _store(tmp_path)
    store.jwt_secret_path.parent.mkdir(parents=True, exist_ok=True)
    store.jwt_secret_path.write_text(content, encoding="utf-8")

    secret = store.ensure_jwt_secret(None)
    assert len(secret.encode("utf-8")) >= MIN_SECRET_BYTES
    assert store.jwt_secret_path.read_text(encoding="utf-8").strip() == secret


def test_user_token_survives_restart_with_generated_secret(tmp_path: Path) -> None:
    """自动生成的密钥也要真的被用上：换个应用实例，之前签发的令牌仍然有效。"""
    settings = make_settings(tmp_path)
    settings.jwt_secret = ""
    with TestClient(create_app(settings)) as client:
        token = client.post(
            "/api/v1/auth/register", json={"username": "alice", "password": PASSWORD}
        ).json()["accessToken"]
        assert client.get("/api/v1/auth/me", headers=auth_headers(token)).status_code == 200
        # resolve 之后 runtime 用的是生成出来的那一份
        assert settings.jwt_secret
    assert (tmp_path / DATA_DIR_NAME / JWT_SECRET_FILE_NAME).exists()

    # 等价于重启：同一份 data_dir 重新组装应用
    again = make_settings(tmp_path)
    again.jwt_secret = ""
    with TestClient(create_app(again)) as client:
        response = client.get("/api/v1/auth/me", headers=auth_headers(token))
        assert response.status_code == 200, "密钥没被复用：重启后所有登录态都会失效"
