"""配置解析测试 —— 重点是**从环境变量读**这条路径。

背景：``ice_servers`` / ``cors_origins`` 曾经只在「用构造参数传值」时工作，
一旦通过环境变量给（也就是 docker-compose 的实际用法），pydantic-settings 会先
拿 ``json.loads`` 解析，遇到 ``stun:host:3478`` 直接抛错，容器起不来。
所以这里要覆盖 env 场景，而不只是 ``Settings(xxx=...)``。
"""

import types
from pathlib import Path
from typing import Any, Union, get_args, get_origin

import pytest

from app.core.config import Settings

#: 单测里需要特殊取值的字段：
#: * heartbeat：跨字段校验（timeout 必须大于 interval）
#: * avatar_max_bytes：默认取样 3600 小于它的下界 8 KiB
_ENV_OVERRIDES: dict[str, str] = {
    "heartbeat_interval_seconds": "30",
    "heartbeat_timeout_seconds": "90",
    "avatar_max_bytes": "1048576",
}


def _compose_environment() -> dict[str, str]:
    """docker-compose 会注入的全部变量（与 docker-compose.yml 保持一致）。"""
    return {
        "OMIOCLINK_JWT_SECRET": "compose-provided-secret-32-bytes-min!!",
        "OMIOCLINK_DATABASE_URL": "sqlite+aiosqlite:////app/data/omioclink.db",
        "OMIOCLINK_DATA_DIR": "/app/data",
        "OMIOCLINK_ALLOW_REGISTRATION": "false",
        "OMIOCLINK_DOCS_ENABLED": "false",
        "OMIOCLINK_ADMIN_TOKEN": "",
        "OMIOCLINK_ICE_SERVERS": "stun:stun.cloudflare.com:3478",
        "OMIOCLINK_CORS_ORIGINS": "*",
    }


def test_settings_accept_compose_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """把 compose 注入的环境变量原样塞进去，Settings() 必须能构造成功。"""
    for key, value in _compose_environment().items():
        monkeypatch.setenv(key, value)

    settings = Settings()

    assert settings.ice_servers == ["stun:stun.cloudflare.com:3478"]
    assert settings.cors_origins == ["*"]
    assert settings.allow_registration is False
    assert settings.docs_enabled is False
    assert settings.admin_enabled is False
    assert settings.database_url.endswith("/app/data/omioclink.db")


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("stun:a:3478,stun:b:3478", ["stun:a:3478", "stun:b:3478"]),
        ("  stun:a:3478 , stun:b:3478  ", ["stun:a:3478", "stun:b:3478"]),
        ("stun:a:3478", ["stun:a:3478"]),
        ('["stun:a:3478","stun:b:3478"]', ["stun:a:3478", "stun:b:3478"]),
        ("", []),
        ("   ", []),
        ("a,,b,", ["a", "b"]),
        ("*", ["*"]),
    ],
)
def test_csv_fields_parse_from_env(
    monkeypatch: pytest.MonkeyPatch, raw: str, expected: list[str]
) -> None:
    monkeypatch.setenv("OMIOCLINK_ICE_SERVERS", raw)
    monkeypatch.setenv("OMIOCLINK_CORS_ORIGINS", raw)
    settings = Settings()
    assert settings.ice_servers == expected
    assert settings.cors_origins == expected


def test_public_stun_default_excludes_unreachable_google() -> None:
    """默认列表里不应有 stun.l.google.com（国内基本不可达）。"""
    default = Settings.model_fields["ice_servers"].get_default(call_default_factory=True)
    assert isinstance(default, list)
    assert all(server.startswith("stun:") for server in default)
    assert not any("google" in server for server in default)


def _sample_env_value(name: str, annotation: Any) -> str | None:
    """按字段类型造一个合法的环境变量字符串；认不出来就返回 None。"""
    if name in _ENV_OVERRIDES:
        return _ENV_OVERRIDES[name]

    origin = get_origin(annotation)
    if origin in (types.UnionType, Union):
        for argument in get_args(annotation):
            if argument is not type(None):
                return _sample_env_value(name, argument)
        return None
    if origin in (list, tuple, set, frozenset):
        return "alpha,beta"
    if annotation is bool:
        return "false"
    if annotation is int:
        # 取大一点，顺带满足 Field(ge=2) 之类的下界
        return "3600"
    if annotation is float:
        return "1.5"
    if annotation is str:
        # 40 字符：顺带满足 jwt_secret 的「至少 32 字节」校验
        return "x" * 40
    if annotation is Path:
        return "/tmp/omioclink-data"
    return None


def test_every_field_is_settable_from_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """逐字段用环境变量覆盖一遍。

    这是「only-kwargs」类配置 bug 的通用防线：任何字段只要不能从 env 正确解析，
    这条用例就红——``ice_servers`` 的 CSV 解析 bug 正是这样漏过去的。
    """
    covered: set[str] = set()
    for name, field in Settings.model_fields.items():
        value = _sample_env_value(name, field.annotation)
        if value is None:
            continue
        monkeypatch.setenv(f"OMIOCLINK_{name.upper()}", value)
        covered.add(name)

    settings = Settings()

    # 列表字段真的要按 CSV 解析出来，而不是静默回落到默认值
    assert settings.ice_servers == ["alpha", "beta"]
    assert settings.cors_origins == ["alpha", "beta"]
    # 标量字段也要真的读进去
    assert settings.port == 3600
    assert settings.allow_registration is False
    assert settings.docs_enabled is False
    assert settings.jwt_secret == "x" * 40
    assert settings.heartbeat_interval_seconds == 30
    assert settings.heartbeat_timeout_seconds == 90

    # 万一将来新增了认不出类型的字段，提醒补进 _sample_env_value
    uncovered = set(Settings.model_fields) - covered
    assert not uncovered, f"这些字段没有覆盖到 env 解析：{sorted(uncovered)}"
