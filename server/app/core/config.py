"""服务端运行配置。

所有配置项均可通过环境变量覆盖，前缀 ``OMIOCLINK_``（也可放在 server/.env）。
"""

import json
from functools import lru_cache
from pathlib import Path
from typing import Annotated, Any

from pydantic import BeforeValidator, Field, ValidationInfo, field_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

from app import __version__

__all__ = ["Settings", "get_settings"]


def _split_csv(value: Any) -> Any:
    """把「逗号分隔字符串 / JSON 数组 / 已解析的列表」统一成字符串列表。

    支持三种写法，便于 .env 与命令行都能用：

        OMIOCLINK_ICE_SERVERS=stun:a:3478,stun:b:3478
        OMIOCLINK_ICE_SERVERS=["stun:a:3478","stun:b:3478"]
        OMIOCLINK_ICE_SERVERS=                → []
    """
    if isinstance(value, str):
        stripped = value.strip()
        if not stripped:
            return []
        if stripped.startswith("["):
            try:
                decoded = json.loads(stripped)
            except ValueError:
                decoded = None
            if isinstance(decoded, list):
                return [str(item).strip() for item in decoded if str(item).strip()]
        return [item.strip() for item in stripped.split(",") if item.strip()]
    return value


#: 逗号分隔的字符串列表。
#:
#: ``NoDecode`` **必须**放在 ``BeforeValidator`` 之前：pydantic-settings 只要看到
#: 注解里有 list，就会先把环境变量值丢给 ``json.loads``（``stun:host:3478`` 会直接
#: 抛 JSONDecodeError 让服务起不来），加了 NoDecode 才会把原始字符串交给我们解析。
#:
#: 注意这个坑用 ``Settings(ice_servers=[...])`` 这类构造参数传值是测不出来的——
#: 那条路径不经过环境变量源，所以 ``tests/test_config.py`` 里专门覆盖了 env 场景。
CsvList = Annotated[list[str], NoDecode, BeforeValidator(_split_csv)]


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="OMIOCLINK_",
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    # ---- 服务标识 ----
    app_name: str = "OmiocLink"
    server_name: str = "OmiocLink 信令服务器"
    #: 版本号来自包元数据（pyproject 的 [project] version），不在代码里写字面量
    version: str = __version__
    protocol_version: int = 1

    # ---- 网络 ----
    host: str = "0.0.0.0"
    #: 默认端口刻意避开 8080 等常见端口，减少与机器上其他服务的冲突
    port: int = 21077
    websocket_path: str = "/ws"
    api_prefix: str = "/api/v1"

    # ---- 存储 ----
    database_url: str = "sqlite+aiosqlite:///./omioclink.db"
    #: 数据目录：头像文件放这里（``<data_dir>/avatars/``）。
    #: 容器里挂的是 /app/data，和 SQLite 同一个卷，备份时一起带走。
    data_dir: Path = Path("data")

    # ---- 头像 ----
    #: 单张头像的字节上限。客户端会先把图缩到 256px 再传，正常只有几十 KB；
    #: 这个值只是兜底，免得有人直接往接口灌大文件。
    avatar_max_bytes: int = Field(default=2 * 1024 * 1024, ge=8 * 1024)

    # ---- 鉴权 ----
    #: HS256 要求密钥不短于 32 字节（RFC 7518 §3.2），部署时务必覆盖
    jwt_secret: str = "dev-only-secret-please-override-me-32b"
    jwt_algorithm: str = "HS256"
    access_token_ttl_seconds: int = 7 * 24 * 3600
    password_min_length: int = 8
    username_pattern: str = r"^[A-Za-z0-9_\-]{3,32}$"

    # ---- 注册策略 ----
    #: 是否允许用户自行注册。默认关闭：账号由管理员控制开放时机（设为 true 后注册，
    #: 再关回去），避免暴露在公网的实例被随意注册。
    #: 也可以在 Web 管理页临时切换（重启后回到这里的值）。
    allow_registration: bool = False

    # ---- 接口文档 ----
    #: 是否暴露 /docs（Swagger UI）与 /openapi.json。
    #: 默认关闭：它们会把整个 API 面（含注册接口的存在）公开给任何能访问端口的人。
    docs_enabled: bool = False

    # ---- Web 管理页 ----
    #: 管理页与管理接口的访问令牌。**留空即完全关闭**——/admin 与 /api/v1/admin/*
    #: 都不会注册，对外连路由都不存在。开启后访问 http://host:port/admin 即可。
    admin_token: str | None = None

    # ---- 房间 ----
    default_room_capacity: int = Field(default=5, ge=2)
    max_room_capacity: int = Field(default=8, ge=2)

    # ---- ICE / STUN 下发（不含任何 TURN，服务器不提供中继） ----
    #: 只放 `stun:` 地址。默认不含 stun.l.google.com —— 它在国内基本不可达，
    #: 配了只会让客户端白做一次候选收集；最稳的做法是自建 STUN（app.stun）。
    ice_servers: CsvList = Field(default_factory=lambda: ["stun:stun.cloudflare.com:3478"])

    # ---- 点歌台（音乐插件订阅）----
    #: 总开关：关掉后客户端不显示点歌台入口。
    #: 服务器只负责下发订阅地址，不解析、不代理任何音乐数据。
    music_enabled: bool = True

    # ---- 心跳 ----
    heartbeat_interval_seconds: int = 30
    heartbeat_timeout_seconds: int = 90
    heartbeat_sweep_seconds: int = 5

    # ---- 会话策略 ----
    kick_duplicate_sessions: bool = True

    # ---- HTTP ----
    cors_origins: CsvList = Field(default_factory=lambda: ["*"])

    @field_validator("jwt_secret")
    @classmethod
    def _check_jwt_secret(cls, value: str) -> str:
        if len(value.encode("utf-8")) < 32:
            raise ValueError("jwt_secret 至少 32 字节（HS256 的最低密钥长度）")
        return value

    @field_validator("heartbeat_timeout_seconds")
    @classmethod
    def _check_heartbeat_timeout(cls, value: int, info: ValidationInfo) -> int:
        interval = info.data.get("heartbeat_interval_seconds", 30)
        if value <= interval:
            raise ValueError("heartbeat_timeout_seconds 必须大于 heartbeat_interval_seconds")
        return value

    @property
    def room_capacity_ceiling(self) -> int:
        """房间容量硬上限（mesh 拓扑下的工程上限）。"""
        return max(self.max_room_capacity, self.default_room_capacity)

    @property
    def admin_enabled(self) -> bool:
        """管理页是否启用（配置了非空令牌才算启用）。"""
        return bool(self.admin_token and self.admin_token.strip())


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
