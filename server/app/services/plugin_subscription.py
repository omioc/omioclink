"""音乐插件订阅地址的存储（MusicFree 插件体系）。

服务器**只保存若干条订阅 URL**：不下载插件、不解析、不代理任何音乐元数据，
也不接触任何音频地址。客户端登录后取到这份列表，自己下载并安装插件，
之后的搜索/播放全部由客户端直连音源完成。

落盘位置：``<data_dir>/plugin-subscription.json``，内容形如::

    {"urls": ["https://example.com/a.json", "https://example.com/b.js"]}

写入用「临时文件 + replace」，保证并发读到的是完整文件而不是写了一半的内容。
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Final
from urllib.parse import urlsplit

from app.core.errors import ValidationError
from app.core.i18n import t

__all__ = [
    "MAX_SUBSCRIPTIONS",
    "MAX_URL_LENGTH",
    "PluginSubscriptionStore",
    "subscription_hash",
]

#: 最多保存多少条订阅（管理页一次列出来也不至于太长）
MAX_SUBSCRIPTIONS: Final = 20

#: 单条 URL 的长度上限
MAX_URL_LENGTH: Final = 500

#: 允许的插件后缀：MusicFree 插件订阅就是一个 ``.js`` 或 ``.json``
_ALLOWED_SUFFIXES: Final = (".js", ".json")

#: 落盘文件名
_FILE_NAME: Final = "plugin-subscription.json"


def subscription_hash(urls: list[str]) -> str:
    """订阅列表的内容哈希（客户端据此判断「要不要重新拉插件」）。

    算法：``sha256:`` + ``sha256("\\n".join(urls))`` 的十六进制摘要。
    空列表同样有稳定值（``sha256("")``），所以「未配置」与「配置过又清空」
    在客户端看来是同一种状态。
    """
    digest = hashlib.sha256("\n".join(urls).encode("utf-8")).hexdigest()
    return f"sha256:{digest}"


def _normalize(raw: object, index: int) -> str:
    """校验单条 URL，返回去空白后的值；不合法时抛 :class:`ValidationError`。"""
    position = t("plugin.position", index=index + 1)
    if not isinstance(raw, str):
        raise ValidationError(
            t("plugin.position_not_string", position=position),
            code="plugin_subscription_invalid",
        )
    url = raw.strip()
    if not url:
        raise ValidationError(
            t("plugin.position_empty", position=position), code="plugin_subscription_invalid"
        )
    if len(url) > MAX_URL_LENGTH:
        raise ValidationError(
            t(
                "plugin.position_too_long",
                position=position,
                length=len(url),
                maximum=MAX_URL_LENGTH,
            ),
            code="plugin_subscription_invalid",
        )
    parts = urlsplit(url)
    if parts.scheme not in {"http", "https"} or not parts.netloc:
        raise ValidationError(
            t("plugin.position_not_absolute", position=position, url=url),
            code="plugin_subscription_invalid",
        )
    if not parts.path.lower().endswith(_ALLOWED_SUFFIXES):
        raise ValidationError(
            t("plugin.position_bad_suffix", position=position, url=url),
            code="plugin_subscription_invalid",
        )
    return url


def _clean(urls: list[str]) -> list[str]:
    """逐条校验 + 保序去重；条数超限时抛错。"""
    seen: dict[str, None] = {}
    for index, raw in enumerate(urls):
        seen.setdefault(_normalize(raw, index), None)
    cleaned = list(seen)
    if len(cleaned) > MAX_SUBSCRIPTIONS:
        raise ValidationError(
            t("plugin.too_many", maximum=MAX_SUBSCRIPTIONS, count=len(cleaned)),
            code="plugin_subscription_invalid",
        )
    return cleaned


class PluginSubscriptionStore:
    """把订阅地址列表存成一个 JSON 文件（不落数据库，不需要迁移）。"""

    def __init__(self, data_dir: Path) -> None:
        self._path = Path(data_dir) / _FILE_NAME

    @property
    def path(self) -> Path:
        return self._path

    async def read(self) -> list[str]:
        """读出订阅列表；文件不存在或内容损坏时返回 ``[]``（绝不抛异常）。"""
        try:
            raw = self._path.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            return []
        try:
            payload = json.loads(raw)
        except ValueError:
            return []
        if not isinstance(payload, dict):
            return []
        urls = payload.get("urls")
        if not isinstance(urls, list):
            return []
        return [item.strip() for item in urls if isinstance(item, str) and item.strip()]

    async def write(self, urls: list[str]) -> list[str]:
        """校验 → 保序去重 → 落盘，返回真正保存下来的列表。"""
        cleaned = _clean(list(urls))
        payload = json.dumps({"urls": cleaned}, ensure_ascii=False, indent=2) + "\n"
        self._path.parent.mkdir(parents=True, exist_ok=True)
        # 先写临时文件再改名：并发读到的一定是完整内容
        temporary = self._path.with_name(f"{self._path.name}.tmp")
        temporary.write_text(payload, encoding="utf-8")
        temporary.replace(self._path)
        return cleaned
