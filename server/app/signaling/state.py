"""房间与成员的实时状态。

这一层是**纯内存状态**（服务器是房间状态的唯一权威），不依赖 FastAPI/Starlette，
便于单元测试直接构造。持久化只发生在 ``RoomDirectory`` 侧（房间元数据）。
"""

from __future__ import annotations

import asyncio
import secrets
from dataclasses import dataclass, field
from datetime import UTC, datetime
from typing import Protocol

from app.signaling.music import RoomMusic
from app.signaling.protocol import MemberInfo

__all__ = [
    "CloseCode",
    "LiveRoom",
    "Peer",
    "PeerChannel",
    "RoomRecord",
    "SignalingState",
    "utcnow",
]

#: peer_id 的取值空间：8 位十六进制，会话级随机，与账号 ID 分离。
_PEER_ID_BYTES = 4
_PEER_ID_MAX_ATTEMPTS = 16


class CloseCode:
    """WebSocket 关闭码（4000-4999 为应用私有区间）。"""

    NORMAL = 1000
    UNAUTHORIZED = 4401
    ROOM_CLOSED = 4403
    HEARTBEAT_TIMEOUT = 4408
    DUPLICATE_SESSION = 4409
    KICKED_BY_ADMIN = 4410
    INTERNAL_ERROR = 4500


def utcnow() -> datetime:
    return datetime.now(UTC)


class PeerChannel(Protocol):
    """Peer 所持有的发送通道（真实实现为 Starlette ``WebSocket``）。"""

    async def send_text(self, data: str) -> None: ...

    async def close(self, code: int = 1000, reason: str | None = None) -> None: ...


@dataclass(frozen=True, slots=True)
class RoomRecord:
    """来自持久层的房间元数据快照。"""

    room_id: str
    name: str
    owner_id: int
    capacity: int
    has_password: bool
    password_hash: str | None
    is_public: bool
    created_at: datetime | None = None


@dataclass(slots=True)
class Peer:
    """一条活跃的信令会话。"""

    peer_id: str
    user_id: int
    username: str
    display_name: str
    avatar: str | None
    channel: PeerChannel
    room_id: str | None = None
    muted: bool = False
    sharing: bool = False
    speaking: bool = False
    joined_at: datetime = field(default_factory=utcnow)
    last_seen: datetime = field(default_factory=utcnow)
    #: 串行化对该会话的写入（WebSocket 不允许并发 send）
    send_lock: asyncio.Lock = field(default_factory=asyncio.Lock)

    def to_member_info(self) -> MemberInfo:
        return MemberInfo(
            peer_id=self.peer_id,
            user_id=self.user_id,
            username=self.username,
            display_name=self.display_name,
            avatar=self.avatar,
            muted=self.muted,
            sharing=self.sharing,
            speaking=self.speaking,
            joined_at=self.joined_at,
        )


@dataclass(slots=True)
class LiveRoom:
    """一个有成员在线的房间（成员清空即回收）。"""

    room_id: str
    name: str
    owner_id: int
    capacity: int
    created_at: datetime = field(default_factory=utcnow)
    peers: dict[str, Peer] = field(default_factory=dict)
    #: 房间共享点歌队列（服务端权威，随房间回收一起消失）
    music: RoomMusic = field(default_factory=RoomMusic)

    @property
    def member_count(self) -> int:
        return len(self.peers)

    @property
    def is_empty(self) -> bool:
        return not self.peers

    @property
    def sharer_peer_id(self) -> str | None:
        for peer in self.peers.values():
            if peer.sharing:
                return peer.peer_id
        return None

    def member_infos(self) -> list[MemberInfo]:
        """按进房时间排序的成员快照，保证所有客户端看到一致顺序。"""
        ordered = sorted(self.peers.values(), key=lambda p: (p.joined_at, p.peer_id))
        return [peer.to_member_info() for peer in ordered]


class SignalingState:
    """peer / room 注册表。所有方法均为同步，天然原子。"""

    def __init__(self) -> None:
        self._peers: dict[str, Peer] = {}
        self._peers_by_user: dict[int, set[str]] = {}
        self._rooms: dict[str, LiveRoom] = {}

    # ---- peer ----
    def new_peer_id(self) -> str:
        for _ in range(_PEER_ID_MAX_ATTEMPTS):
            candidate = secrets.token_hex(_PEER_ID_BYTES)
            if candidate not in self._peers:
                return candidate
        raise RuntimeError("peer_id 空间枯竭")  # pragma: no cover

    def add_peer(self, peer: Peer) -> None:
        self._peers[peer.peer_id] = peer
        self._peers_by_user.setdefault(peer.user_id, set()).add(peer.peer_id)

    def get_peer(self, peer_id: str) -> Peer | None:
        return self._peers.get(peer_id)

    def peers_snapshot(self) -> list[Peer]:
        return list(self._peers.values())

    def peers_of_user(self, user_id: int) -> list[Peer]:
        return [
            peer
            for peer_id in self._peers_by_user.get(user_id, ())
            if (peer := self._peers.get(peer_id)) is not None
        ]

    def remove_peer(self, peer_id: str) -> Peer | None:
        peer = self._peers.get(peer_id)
        if peer is None:
            return None
        # 必须先离房再摘除索引：leave_room 依赖 self._peers 里的这条记录来定位房间，
        # 顺序反了会让掉线者永远留在房间成员表里（幽灵成员 + 房间永不回收）。
        self.leave_room(peer_id)
        self._peers.pop(peer_id, None)
        session_ids = self._peers_by_user.get(peer.user_id)
        if session_ids is not None:
            session_ids.discard(peer_id)
            if not session_ids:
                self._peers_by_user.pop(peer.user_id, None)
        return peer

    def leave_room(self, peer_id: str) -> LiveRoom | None:
        """让某条会话离开房间，但保留会话本身。返回其原本所在（且仍存在）的房间。"""
        peer = self._peers.get(peer_id)
        if peer is None or peer.room_id is None:
            return None
        room = self._rooms.get(peer.room_id)
        peer.room_id = None
        # 离开房间时把「只对房间有意义」的状态一起清掉：同一条信令连接重进房间用的
        # 是同一个 peer 对象，留着 sharing=True 会让快照里自己也显示「正在共享」，
        # 而本地其实没有采集——表现就是重进房间后黑屏、且要先点一次「停止共享」。
        peer.sharing = False
        peer.speaking = False
        if room is None:
            return None
        room.peers.pop(peer_id, None)
        if room.is_empty:
            self._rooms.pop(room.room_id, None)
            return None
        return room

    @property
    def peer_count(self) -> int:
        return len(self._peers)

    def is_user_online(self, user_id: int) -> bool:
        return bool(self._peers_by_user.get(user_id))

    def online_user_ids(self) -> set[int]:
        return set(self._peers_by_user)

    # ---- room ----
    def get_room(self, room_id: str) -> LiveRoom | None:
        return self._rooms.get(room_id)

    def ensure_room(self, record: RoomRecord) -> LiveRoom:
        room = self._rooms.get(record.room_id)
        if room is None:
            room = LiveRoom(
                room_id=record.room_id,
                name=record.name,
                owner_id=record.owner_id,
                capacity=record.capacity,
                created_at=record.created_at or utcnow(),
            )
            self._rooms[record.room_id] = room
        else:
            # 房间名/容量可能被 owner 在 REST 侧改过，实时房间跟随更新
            room.name = record.name
            room.capacity = record.capacity
            room.owner_id = record.owner_id
        return room

    def live_rooms(self) -> list[LiveRoom]:
        return list(self._rooms.values())

    def live_member_count(self, room_id: str) -> int:
        room = self._rooms.get(room_id)
        return room.member_count if room is not None else 0

    @property
    def live_room_count(self) -> int:
        return len(self._rooms)

    @property
    def live_peer_count(self) -> int:
        return len(self._peers)
