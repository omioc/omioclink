"""头像文件的存取。

头像**不进数据库**：库里 ``User.avatar`` 只存一个 16 字符的版本串（图片内容哈希），
文件放在数据目录下。这样成员列表与信令广播里带的永远只是这个短版本串，
不会把几十 KB 的图片塞进每一条成员状态消息里；版本号即内容哈希，
同一张图重复上传得到同一个版本号，客户端缓存天然命中。
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass
from pathlib import Path

__all__ = [
    "AvatarImage",
    "AvatarStore",
    "UnsupportedImageError",
    "sniff_image_type",
]

#: 嗅探出的真实类型 → (文件扩展名, 响应 Content-Type)。
#:
#: 刻意**不接受 SVG**：SVG 可以内嵌脚本，一旦被当图片打开就是一个 XSS 面；
#: 也不接受 BMP/ICO 这类体积收益差的格式。
IMAGE_TYPES: dict[str, tuple[str, str]] = {
    "png": (".png", "image/png"),
    "jpeg": (".jpg", "image/jpeg"),
    "webp": (".webp", "image/webp"),
    "gif": (".gif", "image/gif"),
}

#: 版本串格式：我们自己产出的内容哈希。**必须**校验——它会被拼进文件路径，
#: 放任 ``?v=../../x`` 或 ``?v=*`` 进来就是路径穿越与通配注入。
_VERSION = re.compile(r"^[0-9a-f]{16}$")


class UnsupportedImageError(ValueError):
    """上传的内容不是受支持的图片。"""


def sniff_image_type(data: bytes) -> str | None:
    """按文件头判断真实类型。

    不信任客户端给的 ``Content-Type`` 与文件名后缀：把一段 HTML 命名成 ``a.png``
    再被当成图片响应出去，就是典型的 MIME 混淆攻击。
    """
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if data.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if data.startswith((b"GIF87a", b"GIF89a")):
        return "gif"
    if len(data) >= 12 and data.startswith(b"RIFF") and data[8:12] == b"WEBP":
        return "webp"
    return None


def avatar_version(data: bytes) -> str:
    """头像版本号 = 内容哈希前缀（内容寻址）。"""
    return hashlib.sha256(data).hexdigest()[:16]


@dataclass(frozen=True, slots=True)
class AvatarImage:
    data: bytes
    content_type: str
    version: str


class AvatarStore:
    """把头像文件落在 ``<data_dir>/avatars/<user_id>-<version>.<ext>``。"""

    def __init__(self, data_dir: Path) -> None:
        self._directory = Path(data_dir) / "avatars"

    @property
    def directory(self) -> Path:
        return self._directory

    def save(self, user_id: int, data: bytes) -> str:
        """保存头像并返回版本号；内容不是受支持的图片时抛错。"""
        kind = sniff_image_type(data)
        if kind is None:
            raise UnsupportedImageError
        extension, _ = IMAGE_TYPES[kind]
        version = avatar_version(data)
        self._directory.mkdir(parents=True, exist_ok=True)
        target = self._path(user_id, version, extension)
        if not target.is_file():
            # 先写临时文件再改名：避免并发请求读到写了一半的图片
            temporary = target.with_suffix(f"{target.suffix}.part")
            temporary.write_bytes(data)
            temporary.replace(target)
        # 同一个用户只保留当前这一张
        self.remove(user_id, keep=version)
        return version

    def load(self, user_id: int, version: str) -> AvatarImage | None:
        """读出头像；版本号不合法或文件不存在时返回 None。"""
        if not _VERSION.fullmatch(version):
            return None
        for _kind, (extension, content_type) in IMAGE_TYPES.items():
            path = self._path(user_id, version, extension)
            if path.is_file():
                return AvatarImage(
                    data=path.read_bytes(),
                    content_type=content_type,
                    version=version,
                )
        return None

    def remove(self, user_id: int, *, keep: str | None = None) -> None:
        """删掉该用户除 ``keep`` 之外的所有头像文件（移除头像时 keep=None）。"""
        if not self._directory.is_dir():
            return
        for path in self._directory.glob(f"{user_id}-*"):
            if keep is not None and path.name.startswith(f"{user_id}-{keep}."):
                continue
            path.unlink(missing_ok=True)

    def _path(self, user_id: int, version: str, extension: str) -> Path:
        return self._directory / f"{user_id}-{version}{extension}"
