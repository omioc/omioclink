"""版本号只有一个来源：server/pyproject.toml 的 ``[project] version``。

代码里（``app/__init__.py``、``app/core/config.py``）不允许再写版本字面量 ——
以前三处各写一遍，升版本漏一处就会出现「hello 报 1.0.1、镜像标签却是 1.0.2」
且没人发现。这两条断言把「漏改」变成一次失败的 CI。
"""

from __future__ import annotations

import tomllib
from pathlib import Path

import app
from app.core.config import Settings

_SERVER_ROOT = Path(__file__).resolve().parent.parent


def _pyproject_version() -> str:
    data = tomllib.loads((_SERVER_ROOT / "pyproject.toml").read_text(encoding="utf-8"))
    return str(data["project"]["version"])


def test_package_version_matches_pyproject() -> None:
    assert app.__version__ == _pyproject_version(), (
        "安装的包元数据与 pyproject 不一致：改完 version 记得跑一次 `uv sync`"
        "（元数据是安装时写进去的）"
    )


def test_settings_default_version_uses_package_version() -> None:
    # 看类默认值而不是实例：Settings() 还要 JWT 密钥等必填项，测试里不该为了这条去构造
    assert Settings.model_fields["version"].default == app.__version__
