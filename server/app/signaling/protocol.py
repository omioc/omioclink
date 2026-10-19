"""信令协议（自研 JSON-over-WebSocket，协议版本 v1）。

设计原则
--------
* 服务器是**房间与成员状态的唯一权威**：成员列表、静音状态、谁在共享屏幕都由服务器持有并广播；
* 服务器转发 ``offer`` / ``answer`` / ``candidate`` 时**不解析 SDP**，纯按 ``dst`` 路由；
* **协议里没有聊天消息**：文字聊天走 WebRTC DataChannel（P2P），服务器不承载、不存储；
* 协议里也没有任何媒体/中继语义：服务器不具备转发媒体的能力。

字段命名：线上统一用 camelCase（``roomId`` / ``peerId`` / ``sdpMLineIndex``），
Python 侧用 snake_case + alias 映射。
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated, Any, Literal

from pydantic import BaseModel, ConfigDict, Field, TypeAdapter

__all__ = [
    "PROTOCOL_VERSION",
    "AnswerMessage",
    "AnswerRelay",
    "CandidateMessage",
    "CandidateRelay",
    "ClientMessage",
    "ErrorCode",
    "ErrorMessage",
    "IceCandidate",
    "JoinRoomMessage",
    "KickedMessage",
    "LeaveRoomMessage",
    "MemberInfo",
    "MemberJoinedMessage",
    "MemberLeftMessage",
    "MemberStateChangedMessage",
    "MemberStateMessage",
    "MusicClearMessage",
    "MusicCurrent",
    "MusicEnqueueBatchMessage",
    "MusicEnqueueItem",
    "MusicEnqueueMessage",
    "MusicEntry",
    "MusicEosMessage",
    "MusicModeMessage",
    "MusicRemoveMessage",
    "MusicRequester",
    "MusicSkipMessage",
    "MusicState",
    "MusicStateMessage",
    "OfferMessage",
    "OfferRelay",
    "PingMessage",
    "PongMessage",
    "PongRelay",
    "RoomClosedMessage",
    "RoomStateMessage",
    "RoomSummary",
    "ServerHelloMessage",
    "ServerInfo",
    "UserSummary",
    "dump_message",
    "parse_client_message",
]

PROTOCOL_VERSION = 1


class ErrorCode:
    """服务器返回的机器可读错误码。"""

    INVALID_MESSAGE = "invalid_message"
    UNSUPPORTED_MESSAGE = "unsupported_message"
    NOT_AUTHENTICATED = "not_authenticated"
    NOT_IN_ROOM = "not_in_room"
    ALREADY_IN_ROOM = "already_in_room"
    ROOM_NOT_FOUND = "room_not_found"
    ROOM_FULL = "room_full"
    BAD_PASSWORD = "bad_password"
    PEER_UNAVAILABLE = "peer_unavailable"
    DUPLICATE_SESSION = "duplicate_session"
    #: 点歌（房间共享队列，见 ``signaling/music.py``）
    MUSIC_QUEUE_FULL = "music_queue_full"
    MUSIC_RATE_LIMITED = "music_rate_limited"
    MUSIC_FORBIDDEN = "music_forbidden"
    MUSIC_NOT_FOUND = "music_not_found"
    MUSIC_INVALID_ENTRY = "music_invalid_entry"
    KICKED_BY_ADMIN = "kicked_by_admin"
    INTERNAL_ERROR = "internal_error"

    ALL = (
        INVALID_MESSAGE,
        UNSUPPORTED_MESSAGE,
        NOT_AUTHENTICATED,
        NOT_IN_ROOM,
        ALREADY_IN_ROOM,
        ROOM_NOT_FOUND,
        ROOM_FULL,
        BAD_PASSWORD,
        PEER_UNAVAILABLE,
        DUPLICATE_SESSION,
        MUSIC_QUEUE_FULL,
        MUSIC_RATE_LIMITED,
        MUSIC_FORBIDDEN,
        MUSIC_NOT_FOUND,
        MUSIC_INVALID_ENTRY,
        KICKED_BY_ADMIN,
        INTERNAL_ERROR,
    )


class _CamelModel(BaseModel):
    """线上 camelCase、Python snake_case 的基类。"""

    model_config = ConfigDict(populate_by_name=True, extra="ignore")


# --------------------------------------------------------------------------- #
# 公共结构
# --------------------------------------------------------------------------- #
class UserSummary(_CamelModel):
    id: int
    username: str
    display_name: str = Field(alias="displayName")
    avatar: str | None = None


class ServerInfo(_CamelModel):
    name: str
    version: str
    protocol_version: int = Field(alias="protocolVersion")


class IceCandidate(_CamelModel):
    candidate: str
    sdp_mid: str | None = Field(default=None, alias="sdpMid")
    sdp_mline_index: int | None = Field(default=None, alias="sdpMLineIndex")
    username_fragment: str | None = Field(default=None, alias="usernameFragment")


class MemberInfo(_CamelModel):
    """房间内一名成员的权威状态快照。"""

    peer_id: str = Field(alias="peerId")
    user_id: int = Field(alias="userId")
    username: str
    display_name: str = Field(alias="displayName")
    avatar: str | None = None
    muted: bool = False
    sharing: bool = False
    speaking: bool = False
    joined_at: datetime = Field(alias="joinedAt")


class RoomSummary(_CamelModel):
    room_id: str = Field(alias="roomId")
    name: str
    owner_id: int = Field(alias="ownerId")
    capacity: int
    member_count: int = Field(default=0, alias="memberCount")
    has_password: bool = Field(default=False, alias="hasPassword")
    is_public: bool = Field(default=True, alias="isPublic")
    created_at: datetime | None = Field(default=None, alias="createdAt")


# --------------------------------------------------------------------------- #
# 房间共享点歌队列（氛围音）
# --------------------------------------------------------------------------- #
class MusicRequester(_CamelModel):
    """点歌人（会话级 peer_id + 当时的昵称，头像不需要）。"""

    peer_id: str = Field(alias="peerId")
    display_name: str = Field(alias="displayName")


class MusicEntry(_CamelModel):
    """队列里的一条点歌。

    ``musicInfo`` 是音源搜索返回的**原始对象**，原样保留：直链普遍带时效签名、
    甚至绑 IP，广播出去别人用会 403，所以每台机器各自解析（协议 §4.1）。
    """

    entry_id: str = Field(alias="entryId")
    source: str
    song_id: str = Field(alias="songId")
    music_info: dict[str, Any] = Field(alias="musicInfo")
    title: str = ""
    artist: str = ""
    duration_ms: int | None = Field(default=None, alias="durationMs")
    requested_by: MusicRequester = Field(alias="requestedBy")
    requested_at_ms: int = Field(default=0, alias="requestedAtMs")


class MusicCurrent(MusicEntry):
    """正在播放的那首：多出播放状态与时间锚点。"""

    playing: bool = True
    #: 锚点：服务器时钟的毫秒时刻
    anchor_server_ms: int = Field(default=0, alias="anchorServerMs")
    #: 锚点时刻对应的歌曲进度（毫秒）
    anchor_position_ms: int = Field(default=0, alias="anchorPositionMs")


class MusicState(_CamelModel):
    """点歌队列全量快照（唯一权威，进房快照里也带一份）。"""

    revision: int = 0
    server_time_ms: int = Field(default=0, alias="serverTimeMs")
    current: MusicCurrent | None = None
    queue: list[MusicEntry] = Field(default_factory=list)
    #: 播放模式（房间级）：repeat_all / repeat_one / sequential / shuffle
    mode: str = "repeat_all"


class _BaseMessage(_CamelModel):
    v: int = PROTOCOL_VERSION
    type: str


# --------------------------------------------------------------------------- #
# 客户端 → 服务器
# --------------------------------------------------------------------------- #
class PingMessage(_BaseMessage):
    type: Literal["ping"] = "ping"
    t: float | None = None


#: 心跳应答。服务端下发的 ping 由客户端用 pong 回应，因此该类型双向可用；
#: 客户端自发的心跳同样用 ping/pong 这一对。
class PongRelay(_BaseMessage):
    type: Literal["pong"] = "pong"
    t: float | None = None


class JoinRoomMessage(_BaseMessage):
    type: Literal["join_room"] = "join_room"
    room_id: str = Field(alias="roomId", min_length=1, max_length=32)
    password: str | None = None


class LeaveRoomMessage(_BaseMessage):
    type: Literal["leave_room"] = "leave_room"


class MemberStateMessage(_BaseMessage):
    """成员上报自身状态；只提交非 None 字段。"""

    type: Literal["member_state"] = "member_state"
    muted: bool | None = None
    sharing: bool | None = None
    speaking: bool | None = None


class OfferRelay(_BaseMessage):
    type: Literal["offer"] = "offer"
    dst: str = Field(min_length=1, max_length=32)
    sdp: str


class AnswerRelay(_BaseMessage):
    type: Literal["answer"] = "answer"
    dst: str = Field(min_length=1, max_length=32)
    sdp: str


class CandidateRelay(_BaseMessage):
    type: Literal["candidate"] = "candidate"
    dst: str = Field(min_length=1, max_length=32)
    candidate: IceCandidate | None = None


# ---- 点歌（房间共享队列）----
class MusicEnqueueItem(_CamelModel):
    """单条点歌的字段：单条消息与批量消息共用一套口径。"""

    source: str = Field(min_length=1, max_length=32)
    song_id: str = Field(alias="songId", min_length=1, max_length=128)
    music_info: dict[str, Any] = Field(alias="musicInfo")
    title: str = Field(default="", max_length=200)
    artist: str = Field(default="", max_length=200)
    duration_ms: int | None = Field(default=None, alias="durationMs", ge=0)


class MusicEnqueueMessage(_BaseMessage):
    """点歌入队。``musicInfo`` 是音源原始对象（客户端原样发上来）。"""

    type: Literal["music_enqueue"] = "music_enqueue"
    source: str = Field(min_length=1, max_length=32)
    song_id: str = Field(alias="songId", min_length=1, max_length=128)
    music_info: dict[str, Any] = Field(alias="musicInfo")
    title: str = Field(default="", max_length=200)
    artist: str = Field(default="", max_length=200)
    duration_ms: int | None = Field(default=None, alias="durationMs", ge=0)


class MusicEnqueueBatchMessage(_BaseMessage):
    """一次点一批（歌单「全部加入」）。

    整批算**一次请求**：服务端只按一次冷却计时，所以一批能立刻排进去；
    逐条发的话第 2 条起都会被 ``ENQUEUE_COOLDOWN_MS`` 拦下。
    """

    type: Literal["music_enqueue_batch"] = "music_enqueue_batch"
    #: 条数上限只保护信令帧；真正能进多少由每人配额 + 队列上限决定
    entries: list[MusicEnqueueItem] = Field(min_length=1, max_length=200)


class MusicRemoveMessage(_BaseMessage):
    type: Literal["music_remove"] = "music_remove"
    entry_id: str = Field(alias="entryId", min_length=1, max_length=16)


class MusicSkipMessage(_BaseMessage):
    type: Literal["music_skip"] = "music_skip"
    entry_id: str | None = Field(default=None, alias="entryId", max_length=16)


class MusicClearMessage(_BaseMessage):
    type: Literal["music_clear"] = "music_clear"


class MusicEosMessage(_BaseMessage):
    """客户端上报「本机放完了」：duration 不可信时的兜底。"""

    type: Literal["music_eos"] = "music_eos"
    entry_id: str = Field(alias="entryId", min_length=1, max_length=16)
    revision: int = Field(ge=0)


class MusicModeMessage(_BaseMessage):
    """切换播放模式（房间级：所有人一起变）。"""

    type: Literal["music_mode"] = "music_mode"
    mode: Literal["repeat_all", "repeat_one", "sequential", "shuffle"]


ClientMessage = Annotated[
    PingMessage
    | PongRelay
    | JoinRoomMessage
    | LeaveRoomMessage
    | MemberStateMessage
    | OfferRelay
    | AnswerRelay
    | CandidateRelay
    | MusicEnqueueMessage
    | MusicEnqueueBatchMessage
    | MusicRemoveMessage
    | MusicSkipMessage
    | MusicClearMessage
    | MusicEosMessage
    | MusicModeMessage,
    Field(discriminator="type"),
]

_client_adapter: TypeAdapter[Any] = TypeAdapter(ClientMessage)


def parse_client_message(raw: Any) -> Any:
    """解析客户端消息；不合法时抛 ``pydantic.ValidationError``。"""
    return _client_adapter.validate_python(raw)


# --------------------------------------------------------------------------- #
# 服务器 → 客户端
# --------------------------------------------------------------------------- #
class ServerHelloMessage(_BaseMessage):
    """连接建立后的第一条消息：会话身份 + 服务器能力 + ICE 配置。"""

    type: Literal["hello"] = "hello"
    peer_id: str = Field(alias="peerId")
    protocol_version: int = Field(alias="protocolVersion")
    heartbeat_interval: int = Field(alias="heartbeatInterval")
    ice_servers: list[str] = Field(alias="iceServers")
    room_capacity: int = Field(alias="roomCapacity")
    #: 服务器时钟（毫秒）：客户端第一次时钟偏移估计就用它
    server_time_ms: int = Field(alias="serverTimeMs")
    #: 房间点歌是否可用（服务端能力位）
    music_enabled: bool = Field(default=True, alias="musicEnabled")
    #: 是否支持一次点一批（``music_enqueue_batch``）：老服务器没这个能力位，客户端退回逐条发
    music_batch: bool = Field(default=True, alias="musicBatch")
    server: ServerInfo
    user: UserSummary


class PongMessage(_BaseMessage):
    type: Literal["pong"] = "pong"
    t: float | None = None
    #: SNTP 式偏移估计用：客户端据 t / 收到时刻 / 本值算 offset
    server_time_ms: int = Field(default=0, alias="serverTimeMs")


class RoomStateMessage(_BaseMessage):
    """进房成功后的房间全量快照（权威状态，含点歌队列）。"""

    type: Literal["room_state"] = "room_state"
    room: RoomSummary
    self_peer_id: str = Field(alias="selfPeerId")
    members: list[MemberInfo]
    ice_servers: list[str] = Field(alias="iceServers")
    music: MusicState = Field(default_factory=MusicState)


class MusicStateMessage(_BaseMessage):
    """点歌队列全量快照（任何变化都全量广播，revision 单调递增）。"""

    type: Literal["music_state"] = "music_state"
    revision: int
    server_time_ms: int = Field(alias="serverTimeMs")
    current: MusicCurrent | None = None
    queue: list[MusicEntry] = Field(default_factory=list)
    #: 播放模式（房间级）：与 ``MusicState.mode`` 同一份口径
    mode: str = "repeat_all"


class MemberJoinedMessage(_BaseMessage):
    type: Literal["member_joined"] = "member_joined"
    member: MemberInfo


class MemberLeftMessage(_BaseMessage):
    type: Literal["member_left"] = "member_left"
    peer_id: str = Field(alias="peerId")
    reason: str = "left"


class MemberStateChangedMessage(_BaseMessage):
    type: Literal["member_state_changed"] = "member_state_changed"
    peer_id: str = Field(alias="peerId")
    patch: dict[str, Any]


class OfferMessage(_BaseMessage):
    type: Literal["offer"] = "offer"
    src: str
    sdp: str


class AnswerMessage(_BaseMessage):
    type: Literal["answer"] = "answer"
    src: str
    sdp: str


class CandidateMessage(_BaseMessage):
    type: Literal["candidate"] = "candidate"
    src: str
    candidate: IceCandidate | None = None
    end_of_candidates: bool = Field(default=False, alias="endOfCandidates")


class RoomClosedMessage(_BaseMessage):
    type: Literal["room_closed"] = "room_closed"
    room_id: str = Field(alias="roomId")
    reason: str = "closed"


class KickedMessage(_BaseMessage):
    type: Literal["kicked"] = "kicked"
    reason: str
    code: str = ErrorCode.DUPLICATE_SESSION


class ErrorMessage(_BaseMessage):
    type: Literal["error"] = "error"
    code: str
    message: str
    ref: str | None = None


ServerMessage = (
    ServerHelloMessage
    | PongMessage
    | RoomStateMessage
    | MemberJoinedMessage
    | MemberLeftMessage
    | MemberStateChangedMessage
    | OfferMessage
    | AnswerMessage
    | CandidateMessage
    | MusicStateMessage
    | RoomClosedMessage
    | KickedMessage
    | ErrorMessage
)


def dump_message(message: BaseModel) -> str:
    """序列化为线上 JSON（camelCase）。"""
    return message.model_dump_json(by_alias=True)
