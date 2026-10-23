"""REST 层的请求/响应模型（camelCase 线上格式，与信令层保持一致）。"""

from __future__ import annotations

import re
from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field, field_validator

from app.core.config import Settings
from app.core.i18n import t
from app.core.security import BCRYPT_MAX_BYTES
from app.signaling.protocol import MemberInfo

__all__ = [
    "AdminActionResult",
    "AdminKickRequest",
    "AdminLoginListResponse",
    "AdminLoginRecordResponse",
    "AdminLoginResponse",
    "AdminOverview",
    "AdminPasswordRequest",
    "AdminPluginSubscription",
    "AdminPluginSubscriptionUpdate",
    "AdminRegistrationToggle",
    "AdminSessionStatus",
    "AdminUserListResponse",
    "AdminUserResponse",
    "AdminUserUpdate",
    "FriendListResponse",
    "FriendRequestAction",
    "FriendRequestCreate",
    "FriendRequestListResponse",
    "FriendRequestResponse",
    "FriendResponse",
    "LoginRequest",
    "MemberListResponse",
    "PasswordChangeRequest",
    "PluginSubscriptionResponse",
    "RegisterRequest",
    "RoomCreateRequest",
    "RoomListResponse",
    "RoomResponse",
    "RoomUpdateRequest",
    "ServerInfoResponse",
    "TokenResponse",
    "UpdateProfileRequest",
    "UserProfile",
]


class _Camel(BaseModel):
    model_config = ConfigDict(populate_by_name=True, extra="ignore")


def _validate_password(value: str, settings: Settings | None = None) -> str:
    minimum = settings.password_min_length if settings else 8
    if len(value) < minimum:
        raise ValueError(t("password.too_short", minimum=minimum))
    if len(value.encode("utf-8")) > BCRYPT_MAX_BYTES:
        raise ValueError(t("password.too_long"))
    return value


# --------------------------------------------------------------------------- #
# 账号
# --------------------------------------------------------------------------- #
class RegisterRequest(_Camel):
    username: str = Field(min_length=3, max_length=32)
    password: str = Field(min_length=8, max_length=72)
    display_name: str | None = Field(default=None, alias="displayName", max_length=48)
    avatar: str | None = Field(default=None, max_length=64)

    @field_validator("username")
    @classmethod
    def _check_username(cls, value: str) -> str:
        if not re.fullmatch(r"[A-Za-z0-9_\-]{3,32}", value):
            raise ValueError(t("username.charset"))
        return value


class LoginRequest(_Camel):
    username: str = Field(min_length=1, max_length=32)
    password: str = Field(min_length=1, max_length=72)


class UpdateProfileRequest(_Camel):
    """这里**只有昵称**：头像由 ``POST/DELETE /auth/avatar`` 管理，
    它的值是服务端算出来的内容哈希，不接受客户端自己写。
    """

    #: min_length=1：允许不传（None），但不允许传空昵称
    display_name: str | None = Field(
        default=None, alias="displayName", min_length=1, max_length=48
    )


class PasswordChangeRequest(_Camel):
    """改密码必须带上当前密码——令牌被盗时对方不能直接把密码改掉。

    长度下限这里只做粗筛（与注册一致），真正的下限用服务器配置的
    ``password_min_length`` 在接口里再判一次。
    """

    current_password: str = Field(alias="currentPassword", min_length=1, max_length=72)
    new_password: str = Field(alias="newPassword", min_length=8, max_length=72)


class UserProfile(_Camel):
    id: int
    username: str
    display_name: str = Field(alias="displayName")
    avatar: str | None = None
    created_at: datetime | None = Field(default=None, alias="createdAt")
    online: bool = False


class TokenResponse(_Camel):
    access_token: str = Field(alias="accessToken")
    token_type: str = Field(default="bearer", alias="tokenType")
    expires_in: int = Field(alias="expiresIn")
    user: UserProfile


# --------------------------------------------------------------------------- #
# 房间
# --------------------------------------------------------------------------- #
class RoomCreateRequest(_Camel):
    name: str = Field(min_length=1, max_length=48)
    capacity: int | None = Field(default=None, ge=2, le=8)
    password: str | None = Field(default=None, max_length=72)
    is_public: bool = Field(default=True, alias="isPublic")


class RoomResponse(_Camel):
    room_id: str = Field(alias="roomId")
    name: str
    owner_id: int = Field(alias="ownerId")
    owner_name: str | None = Field(default=None, alias="ownerName")
    capacity: int
    member_count: int = Field(default=0, alias="memberCount")
    has_password: bool = Field(default=False, alias="hasPassword")
    is_public: bool = Field(default=True, alias="isPublic")
    created_at: datetime | None = Field(default=None, alias="createdAt")
    online: bool = Field(default=False, description="房间内当前是否有人")
    joined: bool = Field(default=False, description="当前用户是否在房间内")


class RoomUpdateRequest(_Camel):
    name: str | None = Field(default=None, min_length=1, max_length=48)
    capacity: int | None = Field(default=None, ge=2, le=8)
    is_public: bool | None = Field(default=None, alias="isPublic")


class RoomListResponse(_Camel):
    items: list[RoomResponse]
    total: int


class MemberListResponse(_Camel):
    """房间在线成员（实时状态，非持久数据）。"""

    items: list[MemberInfo]
    total: int


# --------------------------------------------------------------------------- #
# 好友
# --------------------------------------------------------------------------- #
class FriendRequestCreate(_Camel):
    username: str = Field(min_length=1, max_length=32)


class FriendResponse(_Camel):
    user: UserProfile
    online: bool = False


class FriendListResponse(_Camel):
    items: list[FriendResponse]
    total: int


class FriendRequestResponse(_Camel):
    id: int
    user: UserProfile
    direction: str = Field(description="incoming / outgoing")
    created_at: datetime | None = Field(default=None, alias="createdAt")


class FriendRequestListResponse(_Camel):
    items: list[FriendRequestResponse]
    total: int


class FriendRequestAction(_Camel):
    accept: bool = True


# --------------------------------------------------------------------------- #
# 服务器
# --------------------------------------------------------------------------- #
class AdminOverview(_Camel):
    """管理页首屏概览。"""

    server_name: str = Field(alias="serverName")
    version: str
    user_count: int = Field(alias="userCount")
    room_count: int = Field(alias="roomCount")
    public_room_count: int = Field(alias="publicRoomCount")
    live_peer_count: int = Field(alias="livePeerCount")
    live_room_count: int = Field(alias="liveRoomCount")
    allow_registration: bool = Field(alias="allowRegistration")
    docs_enabled: bool = Field(alias="docsEnabled")


class AdminUserResponse(_Camel):
    id: int
    username: str
    display_name: str = Field(alias="displayName")
    created_at: datetime | None = Field(default=None, alias="createdAt")
    online: bool = False
    disabled: bool = False


class AdminUserUpdate(_Camel):
    """管理端改账号状态：禁用 / 启用。

    只提供 ``disabled`` 一个字段——重置密码之类的操作需要另外设计（是否强制改密、
    是否踢下线），先不做半成品。
    """

    disabled: bool


class AdminUserListResponse(_Camel):
    items: list[AdminUserResponse]
    total: int


class AdminKickRequest(_Camel):
    peer_id: str = Field(alias="peerId", min_length=1, max_length=32)


class AdminRegistrationToggle(_Camel):
    allow: bool


class AdminSessionStatus(_Camel):
    """管理台首屏状态：页面据此决定弹哪个框（设置密码 / 密码登录 / 直接进）。

    ``legacyTokenConfigured`` 只为平滑迁移：老部署的 ``OMIOCLINK_ADMIN_TOKEN``
    还能用一段时间，页面上要提示「设完密码它就作废了」。
    """

    initialized: bool
    authenticated: bool = False
    legacy_token_configured: bool = Field(default=False, alias="legacyTokenConfigured")
    password_min_length: int = Field(default=8, alias="passwordMinLength")
    username: str | None = None


class AdminPasswordRequest(_Camel):
    """首次设置密码 / 登录共用：只认一个密码，管理员名固定是 ``admin``。

    长度下限这里只做粗筛，真正的 ``password_min_length`` 在接口里再判一次。
    """

    password: str = Field(min_length=1, max_length=200)


class AdminLoginResponse(_Camel):
    access_token: str = Field(alias="accessToken")
    token_type: str = Field(default="bearer", alias="tokenType")
    expires_in: int = Field(alias="expiresIn")
    username: str


class AdminActionResult(_Camel):
    ok: bool = True
    detail: str | None = None


# --------------------------------------------------------------------------- #
# 点歌台：音乐插件订阅
# --------------------------------------------------------------------------- #
class PluginSubscriptionResponse(_Camel):
    """客户端读到的音乐插件订阅。

    服务器只存这几条 URL：客户端据此自行下载安装 MusicFree 插件，
    搜索/播放全部直连音源，不经过服务器。``hash`` 用于判断「要不要重新拉插件」。
    """

    urls: list[str] = Field(default_factory=list)
    hash: str = ""


class AdminPluginSubscription(_Camel):
    """管理页读到的订阅地址列表。"""

    urls: list[str] = Field(default_factory=list)


class AdminPluginSubscriptionUpdate(_Camel):
    """管理页提交的订阅地址列表。

    这里刻意不加 ``max_length`` 之类的 pydantic 约束：格式问题统一由
    :class:`app.services.plugin_subscription.PluginSubscriptionStore` 校验，
    这样错误码稳定是 ``plugin_subscription_invalid``，客户端只需按一个 code 分支。
    """

    urls: list[str]


class ServerInfoResponse(_Camel):
    name: str
    version: str
    protocol_version: int = Field(alias="protocolVersion")
    room_capacity: int = Field(alias="roomCapacity")
    max_room_capacity: int = Field(alias="maxRoomCapacity")
    ice_servers: list[str] = Field(alias="iceServers")
    heartbeat_interval: int = Field(alias="heartbeatInterval")
    websocket_path: str = Field(alias="websocketPath")
    api_prefix: str = Field(alias="apiPrefix")
    # 是否允许用户自行注册（默认关闭，客户端据此显隐注册入口）
    allow_registration: bool = Field(default=False, alias="allowRegistration")
    # 架构事实：服务器不提供任何媒体中继
    media_relay: bool = Field(default=False, alias="mediaRelay")
    # 点歌台（音乐插件订阅）是否可用：关掉后客户端不显示入口
    music_enabled: bool = Field(default=False, alias="musicEnabled")


class AdminLoginRecordResponse(_Camel):
    """一条登录记录（管理台的安全审计视图）。"""

    source: str
    username: str
    ip: str
    user_agent: str = Field(alias="userAgent")
    success: bool
    created_at: datetime = Field(alias="createdAt")


class AdminLoginListResponse(_Camel):
    items: list[AdminLoginRecordResponse]
    limit: int
    offset: int
