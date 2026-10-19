"""OmiocLink 信令服务器。"""

from __future__ import annotations

import tomllib
from importlib.metadata import PackageNotFoundError
from importlib.metadata import version as _dist_version
from pathlib import Path


def _read_version() -> str:
    """取版本号：先看装好的包元数据，退回读清单文件里的 ``[project] version``。

    版本号只有 ``pyproject.toml`` 一个来源。以前 ``__init__`` / ``core/config`` / ``pyproject``
    三处各写一遍，升版本漏一处就会出现「hello 里报 1.0.1、镜像标签却是 1.0.2」而且没人发现。
    """
    try:
        return _dist_version("omioclink-server")
    except PackageNotFoundError:
        pass
    # 本项目没有 [build-system]，uv 只装依赖不把自身装成包，元数据通常拿不到：直接读清单。
    # Dockerfile 把 pyproject.toml 和源码一起 COPY 进 /app，容器里这条路同样有效。
    pyproject = Path(__file__).resolve().parent.parent / "pyproject.toml"
    try:
        with pyproject.open("rb") as fp:
            return str(tomllib.load(fp)["project"]["version"])
    except (OSError, KeyError):
        return "0.0.0+unknown"


__version__ = _read_version()
