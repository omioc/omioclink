"""服务端自持密钥的落盘存储（目前只有 JWT 签名密钥）。

以前 ``OMIOCLINK_JWT_SECRET`` 是必填项：部署前得先想一个 32 字节的随机串，
忘了填容器直接起不来。现在留空就由服务端自己生成一份并写进
``<data_dir>/jwt-secret``——和 SQLite、头像在同一个卷里，备份时一起带走。

为什么一定要落盘、不能每次启动随机生成：JWT 密钥换了等于「所有已登录设备
立刻掉线」，重启一次的代价太大。
"""

from __future__ import annotations

import contextlib
import logging
import secrets
from pathlib import Path
from typing import Final

logger = logging.getLogger(__name__)

__all__ = ["JWT_SECRET_FILE_NAME", "MIN_SECRET_BYTES", "ServerSecretStore"]

#: 落盘文件名（位于 ``<data_dir>``，与 SQLite / 头像共用一个卷）
JWT_SECRET_FILE_NAME: Final = "jwt-secret"

#: HS256 要求密钥不短于 32 字节（RFC 7518 §3.2）
MIN_SECRET_BYTES: Final = 32


class ServerSecretStore:
    """把「服务端自己生成的密钥」存在数据目录里，重启后原样读回来。"""

    def __init__(self, data_dir: Path) -> None:
        self._data_dir = Path(data_dir)

    @property
    def jwt_secret_path(self) -> Path:
        return self._data_dir / JWT_SECRET_FILE_NAME

    def ensure_jwt_secret(self, configured: str | None) -> str:
        """确定本次运行用的 JWT 密钥。

        优先级：用户配置的值 > 上次生成并落盘的值 > 现场生成一份。
        长度校验在 ``Settings`` 里做（配置值），这里只管「有还是没有」。
        """
        explicit = (configured or "").strip()
        if explicit:
            return explicit
        stored = self._read()
        if stored is not None:
            return stored
        generated = secrets.token_hex(MIN_SECRET_BYTES)  # 64 个十六进制字符 = 32 字节
        self._write(generated)
        logger.warning(
            "未配置 OMIOCLINK_JWT_SECRET，已自动生成签名密钥并保存到 %s"
            "（重启会复用它；删掉这个文件等于让所有已登录设备重新登录）",
            self.jwt_secret_path,
        )
        return generated

    def _read(self) -> str | None:
        """读已落盘的密钥；不存在、读不了或内容明显不对都返回 None（当作没有）。"""
        try:
            raw = self.jwt_secret_path.read_text(encoding="utf-8").strip()
        except FileNotFoundError:
            return None
        except (OSError, UnicodeDecodeError) as exc:
            logger.warning("读取 %s 失败（%s），将重新生成", self.jwt_secret_path, exc)
            return None
        if len(raw.encode("utf-8")) < MIN_SECRET_BYTES:
            logger.warning("%s 内容过短，将重新生成", self.jwt_secret_path)
            return None
        return raw

    def _write(self, secret: str) -> None:
        path = self.jwt_secret_path
        path.parent.mkdir(parents=True, exist_ok=True)
        # 先写临时文件再改名：并发读到的一定是完整内容，不会读到写了一半的密钥
        temporary = path.with_name(f"{path.name}.tmp")
        temporary.write_text(secret + "\n", encoding="utf-8")
        # 先收紧权限再改名，别的用户读不到密钥（Windows 上权限位基本无效，失败也不影响）
        with contextlib.suppress(OSError):
            temporary.chmod(0o600)
        temporary.replace(path)
