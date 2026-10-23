"""信令中枢：连接注册、消息分发、房间广播、心跳巡检。

这里**没有、也不会有**任何媒体转发逻辑：``offer`` / ``answer`` / ``candidate``
只按 ``dst`` / ``src`` 在成员之间路由，服务器不解析 SDP，不拥有任何媒体通道。
"""

from __future__ import annotations

import asyncio
import json
import logging
from collections.abc import Iterable, Sequence
from datetime import timedelta
from typing import Any, Protocol

from pydantic import BaseModel, ValidationError

from app.core.config import Settings
from app.core.i18n import t
from app.core.security import verify_password
from app.signaling.music import EnqueueRequest, MusicError, now_ms
from app.signaling.protocol import (
    PROTOCOL_VERSION,
    AnswerMessage,
    AnswerRelay,
    CandidateMessage,
    CandidateRelay,
    ErrorCode,
    ErrorMessage,
    JoinRoomMessage,
    KickedMessage,
    LeaveRoomMessage,
    MemberJoinedMessage,
    MemberLeftMessage,
    MemberStateChangedMessage,
    MemberStateMessage,
    MusicClearMessage,
    MusicEnqueueBatchMessage,
    MusicEnqueueMessage,
    MusicEosMessage,
    MusicModeMessage,
    MusicRemoveMessage,
    MusicSkipMessage,
    MusicStateMessage,
    OfferMessage,
    OfferRelay,
    PingMessage,
    PongMessage,
    PongRelay,
    RoomClosedMessage,
    RoomStateMessage,
    RoomSummary,
    ServerHelloMessage,
    ServerInfo,
    UserSummary,
    dump_message,
    parse_client_message,
)
from app.signaling.state import (
    CloseCode,
    LiveRoom,
    Peer,
    PeerChannel,
    RoomRecord,
    SignalingState,
    utcnow,
)

logger = logging.getLogger(__name__)

__all__ = ["RoomDirectory", "SignalingHub"]


class RoomDirectory(Protocol):
    """信令层访问持久层房间元数据的端口。"""

    async def load(self, room_id: str) -> RoomRecord | None: ...

    async def record_membership(self, room_id: str, user_id: int) -> None: ...


class SignalingHub:
    def __init__(self, settings: Settings, directory: RoomDirectory) -> None:
        self.settings = settings
        self.directory = directory
        self.state = SignalingState()
        # 保护「检查容量 + 落座」这段临界区；发送不在锁内。
        self._join_mutex = asyncio.Lock()
        self._closing = False

    # ------------------------------------------------------------------ #
    # 生命周期
    # ------------------------------------------------------------------ #
    async def register(
        self,
        channel: PeerChannel,
        *,
        user_id: int,
        username: str,
        display_name: str,
        avatar: str | None,
    ) -> Peer:
        peer = Peer(
            peer_id=self.state.new_peer_id(),
            user_id=user_id,
            username=username,
            display_name=display_name,
            avatar=avatar,
            channel=channel,
        )
        self.state.add_peer(peer)
        logger.info("peer 上线 peer_id=%s user=%s", peer.peer_id, username)

        await self.send(
            peer,
            ServerHelloMessage(
                peer_id=peer.peer_id,
                protocol_version=PROTOCOL_VERSION,
                heartbeat_interval=self.settings.heartbeat_interval_seconds,
                ice_servers=list(self.settings.ice_servers),
                room_capacity=self.settings.default_room_capacity,
                server_time_ms=now_ms(),
                music_enabled=self.settings.music_enabled,
                server=ServerInfo(
                    name=self.settings.server_name,
                    version=self.settings.version,
                    protocol_version=PROTOCOL_VERSION,
                ),
                user=UserSummary(
                    id=user_id,
                    username=username,
                    display_name=display_name,
                    avatar=avatar,
                ),
            ),
        )

        if self.settings.kick_duplicate_sessions:
            await self._kick_duplicate_sessions(peer)
        return peer

    async def _kick_duplicate_sessions(self, peer: Peer) -> None:
        for other in self.state.peers_of_user(peer.user_id):
            if other.peer_id == peer.peer_id:
                continue
            await self.send(
                other,
                KickedMessage(reason="duplicate_session", code=ErrorCode.DUPLICATE_SESSION),
            )
            await self._drop(other, reason="duplicate_session", code=CloseCode.DUPLICATE_SESSION)

    async def unregister(self, peer_id: str, *, reason: str = "disconnected") -> None:
        peer = self.state.get_peer(peer_id)
        if peer is None:
            return
        room_id = peer.room_id
        self.state.remove_peer(peer_id)
        logger.info("peer 下线 peer_id=%s reason=%s", peer_id, reason)
        if room_id is None:
            return
        # remove_peer 之后需重新取房间：最后一人离开时房间已被回收，此时无需广播
        room = self.state.get_room(room_id)
        if room is not None:
            await self._broadcast(
                room.peers.values(), MemberLeftMessage(peer_id=peer_id, reason=reason)
            )

    async def shutdown(self) -> None:
        self._closing = True
        for peer in self.state.peers_snapshot():
            await self._drop(peer, reason="server_shutdown", code=CloseCode.NORMAL)

    async def _drop(self, peer: Peer, *, reason: str, code: int) -> None:
        self.state.remove_peer(peer.peer_id)
        try:
            await peer.channel.close(code=code, reason=reason)
        except Exception:  # pragma: no cover - 对端已断开
            logger.debug("关闭 peer 通道失败 peer_id=%s", peer.peer_id, exc_info=True)

    # ------------------------------------------------------------------ #
    # 发送
    # ------------------------------------------------------------------ #
    async def send(self, peer: Peer, message: BaseModel) -> bool:
        payload = dump_message(message)
        try:
            async with peer.send_lock:
                await peer.channel.send_text(payload)
        except Exception:
            logger.debug("发送失败 peer_id=%s", peer.peer_id, exc_info=True)
            return False
        return True

    async def _broadcast(
        self,
        peers: Iterable[Peer],
        message: BaseModel,
        *,
        exclude: str | None = None,
    ) -> None:
        targets = [peer for peer in peers if peer.peer_id != exclude]
        if not targets:
            return
        await asyncio.gather(
            *(self.send(peer, message) for peer in targets), return_exceptions=True
        )

    async def _broadcast_room(
        self, room: LiveRoom, message: BaseModel, *, exclude: str | None = None
    ) -> None:
        await self._broadcast(list(room.peers.values()), message, exclude=exclude)

    async def _error(self, peer: Peer, code: str, message: str, *, ref: str | None = None) -> None:
        await self.send(peer, ErrorMessage(code=code, message=message, ref=ref))

    # ------------------------------------------------------------------ #
    # 入站消息
    # ------------------------------------------------------------------ #
    async def handle_text(self, peer: Peer, raw: str | bytes) -> None:
        current = self.state.get_peer(peer.peer_id)
        if current is None:  # 已被踢下线
            return
        peer.last_seen = utcnow()
        try:
            payload = json.loads(raw)
        except (ValueError, TypeError):
            await self._error(peer, ErrorCode.INVALID_MESSAGE, t("ws.invalid_json"))
            return
        try:
            message = parse_client_message(payload)
        except ValidationError as exc:
            await self._error(peer, ErrorCode.INVALID_MESSAGE, _format_validation_error(exc))
            return

        if isinstance(message, PingMessage):
            # 顺带回服务器时钟：客户端用 t / 收到时刻 / serverTimeMs 做 SNTP 式偏移估计
            await self.send(peer, PongMessage(t=message.t, server_time_ms=now_ms()))
        elif isinstance(message, PongRelay):
            # 心跳应答：last_seen 已在入口刷新，这里无需再做任何事
            pass
        elif isinstance(message, JoinRoomMessage):
            await self._handle_join_room(peer, message)
        elif isinstance(message, LeaveRoomMessage):
            await self._handle_leave_room(peer)
        elif isinstance(message, MemberStateMessage):
            await self._handle_member_state(peer, message)
        elif isinstance(message, (OfferRelay, AnswerRelay, CandidateRelay)):
            await self._handle_relay(peer, message)
        elif isinstance(message, MusicEnqueueMessage):
            await self._handle_music_enqueue(peer, message)
        elif isinstance(message, MusicEnqueueBatchMessage):
            await self._handle_music_enqueue_batch(peer, message)
        elif isinstance(message, MusicRemoveMessage):
            await self._handle_music_remove(peer, message)
        elif isinstance(message, MusicSkipMessage):
            await self._handle_music_skip(peer, message)
        elif isinstance(message, MusicClearMessage):
            await self._handle_music_clear(peer)
        elif isinstance(message, MusicEosMessage):
            await self._handle_music_eos(peer, message)
        elif isinstance(message, MusicModeMessage):
            await self._handle_music_mode(peer, message)
        else:  # pragma: no cover - 受 discriminated union 保护
            await self._error(peer, ErrorCode.UNSUPPORTED_MESSAGE, t("ws.unsupported_message"))

    async def _handle_join_room(self, peer: Peer, message: JoinRoomMessage) -> None:
        if peer.room_id is not None:
            if peer.room_id == message.room_id:
                return  # 幂等：重复 join 同一房间直接忽略
            await self._error(peer, ErrorCode.ALREADY_IN_ROOM, t("ws.already_in_room"))
            return

        record = await self.directory.load(message.room_id)
        if record is None:
            await self._error(
                peer, ErrorCode.ROOM_NOT_FOUND, t("ws.room_not_found"), ref=message.room_id
            )
            return
        if record.has_password and not verify_password(
            message.password or "", record.password_hash
        ):
            await self._error(
                peer, ErrorCode.BAD_PASSWORD, t("ws.bad_password"), ref=message.room_id
            )
            return

        async with self._join_mutex:
            room = self.state.ensure_room(record)
            if room.member_count >= room.capacity:
                await self._error(peer, ErrorCode.ROOM_FULL, t("ws.room_full"), ref=message.room_id)
                return
            peer.room_id = room.room_id
            room.peers[peer.peer_id] = peer
            members = room.member_infos()
            others = [p for p in room.peers.values() if p.peer_id != peer.peer_id]
            summary = RoomSummary(
                room_id=room.room_id,
                name=room.name,
                owner_id=room.owner_id,
                capacity=room.capacity,
                member_count=room.member_count,
                has_password=record.has_password,
                is_public=record.is_public,
                created_at=room.created_at,
            )

        # 先落进房历史再回 room_state：客户端收到 ack 后往往会立刻刷新「我的房间」，
        # 顺序反了的话那次刷新会查不到这个房间（要等下一轮轮询才出现）
        await self._record_membership(peer, room)

        await self.send(
            peer,
            RoomStateMessage(
                room=summary,
                self_peer_id=peer.peer_id,
                members=members,
                ice_servers=list(self.settings.ice_servers),
                # 进房即拿到权威的点歌队列（含当前曲与锚点）
                music=room.music.snapshot(now_ms()),
            ),
        )
        await self._broadcast(others, MemberJoinedMessage(member=peer.to_member_info()))
        logger.info("peer %s 进入房间 %s", peer.peer_id, room.room_id)

    async def _record_membership(self, peer: Peer, room: LiveRoom) -> None:
        try:
            await self.directory.record_membership(room.room_id, peer.user_id)
        except Exception:  # pragma: no cover - 记录失败不影响通话
            logger.warning("记录进房历史失败 room=%s", room.room_id, exc_info=True)

    async def _handle_leave_room(self, peer: Peer) -> None:
        room_id = peer.room_id
        if room_id is None:
            return
        room = self.state.leave_room(peer.peer_id)
        logger.info("peer %s 离开房间 %s", peer.peer_id, room_id)
        if room is not None:
            await self._broadcast_room(
                room, MemberLeftMessage(peer_id=peer.peer_id, reason="left")
            )

    async def _handle_member_state(self, peer: Peer, message: MemberStateMessage) -> None:
        if peer.room_id is None:
            await self._error(peer, ErrorCode.NOT_IN_ROOM, t("ws.not_in_room"))
            return
        patch: dict[str, bool] = {}
        if message.muted is not None and message.muted != peer.muted:
            peer.muted = message.muted
            patch["muted"] = message.muted
        if message.sharing is not None and message.sharing != peer.sharing:
            peer.sharing = message.sharing
            patch["sharing"] = message.sharing
        if message.speaking is not None and message.speaking != peer.speaking:
            peer.speaking = message.speaking
            patch["speaking"] = message.speaking
        if not patch:
            return
        room = self.state.get_room(peer.room_id)
        if room is None:  # pragma: no cover - 状态与房间一致性由 leave/member 流程保证
            return
        await self._broadcast_room(
            room,
            MemberStateChangedMessage(peer_id=peer.peer_id, patch=patch),
            exclude=peer.peer_id,
        )

    async def _handle_relay(
        self, peer: Peer, message: OfferRelay | AnswerRelay | CandidateRelay
    ) -> None:
        if peer.room_id is None:
            await self._error(peer, ErrorCode.NOT_IN_ROOM, t("ws.not_in_room"))
            return
        target = self.state.get_peer(message.dst)
        if target is None or target.room_id != peer.room_id:
            await self._error(
                peer,
                ErrorCode.PEER_UNAVAILABLE,
                t("ws.peer_unavailable"),
                ref=message.dst,
            )
            return
        if isinstance(message, OfferRelay):
            await self.send(target, OfferMessage(src=peer.peer_id, sdp=message.sdp))
        elif isinstance(message, AnswerRelay):
            await self.send(target, AnswerMessage(src=peer.peer_id, sdp=message.sdp))
        else:
            await self.send(
                target,
                CandidateMessage(
                    src=peer.peer_id,
                    candidate=message.candidate,
                    end_of_candidates=message.candidate is None,
                ),
            )

    # ------------------------------------------------------------------ #
    # 房间共享点歌队列（氛围音）
    # ------------------------------------------------------------------ #
    async def _broadcast_music_state(self, room: LiveRoom) -> None:
        """任何变化都全量广播一次（revision 单调递增，客户端据此丢弃过期消息）。"""
        state = room.music.snapshot(now_ms())
        await self._broadcast_room(
            room,
            MusicStateMessage(
                revision=state.revision,
                server_time_ms=state.server_time_ms,
                current=state.current,
                queue=state.queue,
                mode=state.mode,
            ),
        )

    def _music_room(self, peer: Peer) -> LiveRoom | None:
        if peer.room_id is None:
            return None
        return self.state.get_room(peer.room_id)

    async def _handle_music_enqueue(self, peer: Peer, message: MusicEnqueueMessage) -> None:
        room = self._music_room(peer)
        if room is None:
            await self._error(peer, ErrorCode.NOT_IN_ROOM, t("ws.not_in_room"), ref="music_enqueue")
            return
        if not self.settings.music_enabled:
            await self._error(
                peer, ErrorCode.MUSIC_FORBIDDEN, t("ws.music_disabled"), ref="music_enqueue"
            )
            return
        try:
            room.music.enqueue(
                peer_id=peer.peer_id,
                display_name=peer.display_name,
                source=message.source,
                song_id=message.song_id,
                music_info=message.music_info,
                title=message.title,
                artist=message.artist,
                duration_ms=message.duration_ms,
                now=now_ms(),
            )
        except MusicError as error:
            await self._error(peer, error.code, error.message, ref="music_enqueue")
            return
        await self._broadcast_music_state(room)

    async def _handle_music_enqueue_batch(
        self, peer: Peer, message: MusicEnqueueBatchMessage
    ) -> None:
        """一次点一批：整批算一次请求，只广播一次状态。"""
        room = self._music_room(peer)
        if room is None:
            await self._error(
                peer, ErrorCode.NOT_IN_ROOM, t("ws.not_in_room"), ref="music_enqueue_batch"
            )
            return
        if not self.settings.music_enabled:
            await self._error(
                peer,
                ErrorCode.MUSIC_FORBIDDEN,
                t("ws.music_disabled"),
                ref="music_enqueue_batch",
            )
            return
        try:
            room.music.enqueue_many(
                peer_id=peer.peer_id,
                display_name=peer.display_name,
                requests=[
                    EnqueueRequest(
                        source=entry.source,
                        song_id=entry.song_id,
                        music_info=entry.music_info,
                        title=entry.title,
                        artist=entry.artist,
                        duration_ms=entry.duration_ms,
                    )
                    for entry in message.entries
                ],
                now=now_ms(),
            )
        except MusicError as error:
            await self._error(peer, error.code, error.message, ref="music_enqueue_batch")
            return
        await self._broadcast_music_state(room)

    async def _handle_music_remove(self, peer: Peer, message: MusicRemoveMessage) -> None:
        room = self._music_room(peer)
        if room is None:
            await self._error(peer, ErrorCode.NOT_IN_ROOM, t("ws.not_in_room"), ref="music_remove")
            return
        try:
            room.music.remove(
                peer_id=peer.peer_id,
                is_owner=room.owner_id == peer.user_id,
                entry_id=message.entry_id,
                now=now_ms(),
            )
        except MusicError as error:
            await self._error(peer, error.code, error.message, ref="music_remove")
            return
        await self._broadcast_music_state(room)

    async def _handle_music_skip(self, peer: Peer, message: MusicSkipMessage) -> None:
        room = self._music_room(peer)
        if room is None:
            await self._error(peer, ErrorCode.NOT_IN_ROOM, t("ws.not_in_room"), ref="music_skip")
            return
        try:
            room.music.skip(
                peer_id=peer.peer_id,
                is_owner=room.owner_id == peer.user_id,
                entry_id=message.entry_id,
                now=now_ms(),
            )
        except MusicError as error:
            await self._error(peer, error.code, error.message, ref="music_skip")
            return
        await self._broadcast_music_state(room)

    async def _handle_music_clear(self, peer: Peer) -> None:
        room = self._music_room(peer)
        if room is None:
            await self._error(peer, ErrorCode.NOT_IN_ROOM, t("ws.not_in_room"), ref="music_clear")
            return
        try:
            room.music.clear(is_owner=room.owner_id == peer.user_id)
        except MusicError as error:
            await self._error(peer, error.code, error.message, ref="music_clear")
            return
        await self._broadcast_music_state(room)

    async def _handle_music_eos(self, peer: Peer, message: MusicEosMessage) -> None:
        """客户端上报「本机放完了」：duration 不可信时的兜底（revision 幂等）。"""
        room = self._music_room(peer)
        if room is None:
            return
        advanced = room.music.report_eos(
            entry_id=message.entry_id, revision=message.revision, now=now_ms()
        )
        if advanced:
            await self._broadcast_music_state(room)

    async def _handle_music_mode(self, peer: Peer, message: MusicModeMessage) -> None:
        """切换播放模式：房间级设置，谁都能改（和点歌一样开放）。"""
        room = self._music_room(peer)
        if room is None:
            await self._error(peer, ErrorCode.NOT_IN_ROOM, t("ws.not_in_room"), ref="music_mode")
            return
        if not self.settings.music_enabled:
            await self._error(
                peer, ErrorCode.MUSIC_FORBIDDEN, t("ws.music_disabled"), ref="music_mode"
            )
            return
        try:
            room.music.set_mode(message.mode)
        except MusicError as error:
            await self._error(peer, error.code, error.message, ref="music_mode")
            return
        await self._broadcast_music_state(room)

    async def music_tick_loop(self) -> None:
        """每秒推进一次：到点就切下一首（duration 可信时不必等客户端上报 EOS）。"""
        try:
            while not self._closing:
                await asyncio.sleep(1)
                now = now_ms()
                for room in self.state.live_rooms():
                    if room.music.tick(now):
                        await self._broadcast_music_state(room)
        except asyncio.CancelledError:  # pragma: no cover - 正常停机
            raise
    # ------------------------------------------------------------------ #
    # 由 REST 侧驱动的房间管理
    # ------------------------------------------------------------------ #
    async def sync_user_profile(
        self, user_id: int, *, display_name: str, avatar: str | None
    ) -> None:
        """把账号资料（昵称 / 头像版本）同步到它所有在线会话所在的房间。

        资料的权威值在数据库（REST 侧负责落库），这里只更新内存里的成员快照并广播补丁，
        让同房间的人不用退出重进就能看到新昵称与新头像。
        ``avatar`` 传 None 表示「没有头像」，补丁里会带一个显式的 null，
        客户端据此把头像清掉。
        """
        for peer in self.state.peers_of_user(user_id):
            patch: dict[str, Any] = {}
            if peer.display_name != display_name:
                peer.display_name = display_name
                patch["displayName"] = display_name
            if peer.avatar != avatar:
                peer.avatar = avatar
                patch["avatar"] = avatar
            if not patch:
                continue
            room_id = peer.room_id
            if room_id is None:
                continue
            room = self.state.get_room(room_id)
            if room is None:
                continue
            await self._broadcast_room(
                room,
                MemberStateChangedMessage(peer_id=peer.peer_id, patch=patch),
            )

    async def close_room(self, room_id: str, *, reason: str = "closed") -> None:
        """房间被解散：通知房间内所有成员并断开其信令连接。"""
        room = self.state.get_room(room_id)
        if room is None:
            return
        peers: Sequence[Peer] = list(room.peers.values())
        await self._broadcast_room(room, RoomClosedMessage(room_id=room_id, reason=reason))
        for peer in peers:
            await self._drop(peer, reason=reason, code=CloseCode.ROOM_CLOSED)

    async def kick_peer(self, peer_id: str, *, reason: str = ErrorCode.KICKED_BY_ADMIN) -> bool:
        """把某条会话踢下线（管理页用）。返回该会话是否存在。

        注意广播顺序：先 unregister（它会向房间内其他人广播 member_left），
        再 _drop 关连接——顺序反了的话 unregister 会因为 peer 已被摘除而提前返回，
        房间里其他人会一直以为被踢的人还在。
        """
        peer = self.state.get_peer(peer_id)
        if peer is None:
            return False
        await self.send(peer, KickedMessage(reason=reason, code=ErrorCode.KICKED_BY_ADMIN))
        await self.unregister(peer_id, reason=reason)
        await self._drop(peer, reason=reason, code=CloseCode.KICKED_BY_ADMIN)
        return True

    async def kick_user(self, user_id: int, *, reason: str = ErrorCode.KICKED_BY_ADMIN) -> int:
        """踢掉某个账号的所有在线会话（管理端禁用/删除账号时用），返回被踢数量。"""
        kicked = 0
        for peer in self.state.peers_of_user(user_id):
            if await self.kick_peer(peer.peer_id, reason=reason):
                kicked += 1
        return kicked

    async def leave_room_for_user(self, user_id: int, room_id: str) -> int:
        """让某个账号在该房间内的所有在线会话离房（REST 侧的兜底退出）。"""
        left = 0
        for peer in self.state.peers_of_user(user_id):
            if peer.room_id == room_id:
                await self._handle_leave_room(peer)
                left += 1
        return left

    async def kick_room_members(self, room_id: str, *, reason: str = "room_updated") -> None:
        """房间容量等元数据变更后，把超出容量的成员请出房间（保留连接）。"""
        room = self.state.get_room(room_id)
        if room is None:
            return
        members = sorted(room.peers.values(), key=lambda p: (p.joined_at, p.peer_id))
        for peer in members[room.capacity :]:
            self.state.leave_room(peer.peer_id)
            await self.send(peer, RoomClosedMessage(room_id=room_id, reason=reason))
            await self._broadcast_room(
                room, MemberLeftMessage(peer_id=peer.peer_id, reason=reason)
            )

    # ------------------------------------------------------------------ #
    # 心跳
    # ------------------------------------------------------------------ #
    async def heartbeat_loop(self) -> None:
        """周期性：对静默会话发 app 层 ping，并把超时会话踢下线。"""
        interval = timedelta(seconds=self.settings.heartbeat_interval_seconds)
        timeout = timedelta(seconds=self.settings.heartbeat_timeout_seconds)
        try:
            while not self._closing:
                await asyncio.sleep(self.settings.heartbeat_sweep_seconds)
                now = utcnow()
                for peer in self.state.peers_snapshot():
                    idle = now - peer.last_seen
                    if idle > timeout:
                        logger.info("peer %s 心跳超时", peer.peer_id)
                        await self.unregister(peer.peer_id, reason="heartbeat_timeout")
                        await self._drop(
                            peer, reason="heartbeat_timeout", code=CloseCode.HEARTBEAT_TIMEOUT
                        )
                    elif idle >= interval:
                        await self.send(peer, PingMessage())
        except asyncio.CancelledError:  # pragma: no cover - 正常停机
            raise

    # ------------------------------------------------------------------ #
    # 观测
    # ------------------------------------------------------------------ #
    def stats(self) -> dict[str, int]:
        return {
            "peers": self.state.live_peer_count,
            "rooms": self.state.live_room_count,
        }


def _format_validation_error(exc: ValidationError) -> str:
    errors = exc.errors()
    if not errors:
        return t("ws.validation_failed")
    # loc 形如 ("join_room", "roomId")：取末段即线上字段名（pydantic 用 alias）。
    # 判别式不匹配时 loc 为空元组，此时只回报 pydantic 的原始描述。
    loc = errors[0].get("loc") or ()
    reason = errors[0].get("msg", t("ws.validation_failed"))
    if not loc:
        return str(reason)
    return t("ws.field_validation", field=loc[-1], reason=reason)
