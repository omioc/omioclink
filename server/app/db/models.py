"""ORM 模型。

服务器只持久化「账号 / 好友关系 / 房间元数据 / 进房历史」——
不落任何媒体、不落聊天内容（聊天走 P2P DataChannel），
也没有任何音乐元数据表（插件订阅地址存在 data 目录的 JSON 文件里）。
"""

from datetime import UTC, datetime

from sqlalchemy import (
    Boolean,
    DateTime,
    ForeignKey,
    Integer,
    String,
    UniqueConstraint,
)
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base

__all__ = [
    "Friendship",
    "FriendshipStatus",
    "Room",
    "RoomMembership",
    "User",
    "utcnow",
]


def utcnow() -> datetime:
    return datetime.now(UTC)


class FriendshipStatus:
    PENDING = "pending"
    ACCEPTED = "accepted"

    ALL = (PENDING, ACCEPTED)


class User(Base):
    __tablename__ = "users"

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(32), unique=True, index=True)
    display_name: Mapped[str] = mapped_column(String(48))
    password_hash: Mapped[str] = mapped_column(String(128))
    avatar: Mapped[str | None] = mapped_column(String(64), default=None)
    #: 被管理员禁用后：不能登录、已签发的令牌立即失效、在线会话被踢下线
    disabled: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Room(Base):
    __tablename__ = "rooms"

    id: Mapped[str] = mapped_column(String(12), primary_key=True)
    name: Mapped[str] = mapped_column(String(48))
    owner_id: Mapped[int] = mapped_column(
        ForeignKey("users.id", ondelete="CASCADE"), index=True
    )
    capacity: Mapped[int] = mapped_column(Integer, default=5)
    has_password: Mapped[bool] = mapped_column(Boolean, default=False)
    password_hash: Mapped[str | None] = mapped_column(String(128), default=None)
    is_public: Mapped[bool] = mapped_column(Boolean, default=True, index=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )


class RoomMembership(Base):
    """用户进房历史，用于「我的房间」列表（服务器不记录会话内容）。"""

    __tablename__ = "room_memberships"
    __table_args__ = (UniqueConstraint("room_id", "user_id", name="uq_room_membership"),)

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    room_id: Mapped[str] = mapped_column(ForeignKey("rooms.id", ondelete="CASCADE"), index=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    last_joined_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)


class Friendship(Base):
    """好友关系。

    ``accepted`` 后写入双向两行，便于直接按 ``user_id`` 查询好友列表；
    ``pending`` 只存在一行（requester → addressee）。
    """

    __tablename__ = "friendships"
    __table_args__ = (
        UniqueConstraint("user_id", "friend_id", name="uq_friendship_pair"),
    )

    id: Mapped[int] = mapped_column(Integer, primary_key=True, autoincrement=True)
    user_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    friend_id: Mapped[int] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    status: Mapped[str] = mapped_column(String(16), default=FriendshipStatus.PENDING)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), default=utcnow, onupdate=utcnow
    )

