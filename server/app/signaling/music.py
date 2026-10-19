"""房间音乐（氛围音）的服务端权威状态。

* 队列与当前曲**只存在于内存**，房间回收即消失（设计见 ``docs/氛围音技术调研报告.md`` §4）；
* 同步靠「锚点」：``anchorServerMs`` + ``anchorPositionMs``，客户端自己算时钟偏移；
* 推进由两路互补：``tick()``（duration 可信时按秒推进）与客户端上报的 ``music_eos``
  （duration 不可信时的兜底）；``revision`` 单调递增，过期的 EOS 直接忽略；
* 本期不做 seek / 暂停 / 恢复：氛围音是「一起听」，暂停语义留给以后。

这个模块不依赖 FastAPI/WebSocket，``now`` 一律由调用方传入，便于单元测试直接构造。
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from typing import Any

from app.signaling.protocol import (
    ErrorCode,
    MusicCurrent,
    MusicEntry,
    MusicRequester,
    MusicState,
)

__all__ = [
    "END_GRACE_MS",
    "ENQUEUE_COOLDOWN_MS",
    "MAX_MUSIC_INFO_BYTES",
    "MAX_QUEUE_SIZE",
    "PER_USER_QUEUE_LIMIT",
    "PREROLL_MS",
    "UNKNOWN_DURATION_CAP_MS",
    "MusicError",
    "RoomMusic",
    "now_ms",
]
#: 队列上限：与信令帧大小折中（协议 §4.1）
MAX_QUEUE_SIZE = 30
#: 单条 ``musicInfo`` 的 JSON 上限（字节）：保护信令帧
MAX_MUSIC_INFO_BYTES = 2048
#: 每个点歌人最多同时占用的条目数（含正在播的那首）
PER_USER_QUEUE_LIMIT = 2
#: 两次点歌的最小间隔（毫秒）
ENQUEUE_COOLDOWN_MS = 10_000
#: 切歌预滚：给各客户端留出「解析直链 → 打开 → 缓冲」的时间（协议 §5.2）
PREROLL_MS = 3_000
#: 时长结束后的宽限：各端播放器落点有抖动，别让 tick 抢在客户端前面切
END_GRACE_MS = 1_500
#: duration 未知时的兜底上限：只靠 EOS 的话，一个卡住的客户端能把整间房拖住
UNKNOWN_DURATION_CAP_MS = 15 * 60 * 1000


def now_ms() -> int:
    """服务器时钟（毫秒）。锚点与时钟偏移都用它，与客户端墙上时间无关。"""
    return int(time.time() * 1000)


class MusicError(Exception):
    """点歌操作的拒绝原因（``code`` 直接映射协议 ``ErrorCode``）。"""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


@dataclass(slots=True)
class RoomMusic:
    """一个房间的点歌状态（挂在 :class:`LiveRoom` 上）。"""

    revision: int = 0
    current: MusicCurrent | None = None
    queue: list[MusicEntry] = field(default_factory=list)
    #: 条目自增序号：entryId 只需在房间内唯一且可读
    _seq: int = 0
    #: 每个点歌人上次点歌的时刻（毫秒），用于冷却
    _last_enqueue_ms: dict[str, int] = field(default_factory=dict)

    # ------------------------------------------------------------------ 查询
    @property
    def is_empty(self) -> bool:
        return self.current is None and not self.queue

    @property
    def size(self) -> int:
        return len(self.queue) + (0 if self.current is None else 1)

    def snapshot(self, server_time_ms: int) -> MusicState:
        """全量快照：`music_state` 广播与 `room_state.music` 用的是同一份。"""
        return MusicState(
            revision=self.revision,
            server_time_ms=server_time_ms,
            current=self.current,
            queue=list(self.queue),
        )

    def position_ms(self, now: int) -> int:
        """当前曲在 ``now`` 时刻应有的进度（毫秒）；没在播就是 0。"""
        current = self.current
        if current is None or not current.playing:
            return 0
        elapsed = now - current.anchor_server_ms
        if elapsed < 0:
            return current.anchor_position_ms
        position = current.anchor_position_ms + elapsed
        duration = current.duration_ms
        if duration is not None:
            position = min(position, duration)
        return position

    # ------------------------------------------------------------------ 写操作
    def enqueue(
        self,
        *,
        peer_id: str,
        display_name: str,
        source: str,
        song_id: str,
        music_info: dict[str, Any],
        title: str,
        artist: str,
        duration_ms: int | None,
        now: int,
    ) -> MusicEntry:
        """点歌入队；被拒时抛 :class:`MusicError`。"""
        size = len(
            json.dumps(music_info, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        )
        if size > MAX_MUSIC_INFO_BYTES:
            raise MusicError(
                ErrorCode.MUSIC_INVALID_ENTRY,
                f"歌曲信息太大（{size} 字节，上限 {MAX_MUSIC_INFO_BYTES}）",
            )
        if len(self.queue) >= MAX_QUEUE_SIZE:
            raise MusicError(ErrorCode.MUSIC_QUEUE_FULL, "点歌队列已满，等会儿再点")
        if self._mine_count(peer_id) >= PER_USER_QUEUE_LIMIT:
            raise MusicError(
                ErrorCode.MUSIC_QUEUE_FULL,
                f"每人最多同时点 {PER_USER_QUEUE_LIMIT} 首，等自己的歌播完再点",
            )
        last = self._last_enqueue_ms.get(peer_id)
        if last is not None and now - last < ENQUEUE_COOLDOWN_MS:
            wait = (ENQUEUE_COOLDOWN_MS - (now - last) + 999) // 1000
            raise MusicError(ErrorCode.MUSIC_RATE_LIMITED, f"点歌太快了，{wait} 秒后再试")
        if any(item.source == source and item.song_id == song_id for item in self._entries()):
            raise MusicError(ErrorCode.MUSIC_INVALID_ENTRY, "这首歌已经在队列里了")

        self._seq += 1
        entry = MusicEntry(
            entry_id=f"e{self._seq}",
            source=source,
            song_id=song_id,
            music_info=music_info,
            title=title,
            artist=artist,
            duration_ms=duration_ms,
            requested_by=MusicRequester(peer_id=peer_id, display_name=display_name),
            requested_at_ms=now,
        )
        self._last_enqueue_ms[peer_id] = now
        self.queue.append(entry)
        self._ensure_started(now)
        self.revision += 1
        return entry

    def remove(self, *, peer_id: str, is_owner: bool, entry_id: str, now: int) -> None:
        """删除一条：本人或房主可删；删的是当前曲就等于切歌。"""
        if self.current is not None and self.current.entry_id == entry_id:
            self._check_current_control(peer_id=peer_id, is_owner=is_owner)
            self._advance(now)
            return
        for index, entry in enumerate(self.queue):
            if entry.entry_id != entry_id:
                continue
            if not is_owner and entry.requested_by.peer_id != peer_id:
                raise MusicError(ErrorCode.MUSIC_FORBIDDEN, "只能删除自己点的歌")
            self.queue.pop(index)
            self.revision += 1
            return
        raise MusicError(ErrorCode.MUSIC_NOT_FOUND, "这首歌已经不在队列里了")

    def skip(self, *, peer_id: str, is_owner: bool, entry_id: str | None, now: int) -> None:
        """切歌：房主或当前曲点歌人可切。"""
        current = self.current
        if current is None:
            raise MusicError(ErrorCode.MUSIC_NOT_FOUND, "现在没有正在播放的歌")
        if entry_id is not None and entry_id != current.entry_id:
            raise MusicError(ErrorCode.MUSIC_NOT_FOUND, "这首歌已经不是当前曲了")
        self._check_current_control(peer_id=peer_id, is_owner=is_owner)
        self._advance(now)

    def clear(self, *, is_owner: bool) -> None:
        """清空队列并停止（房主专属）。"""
        if not is_owner:
            raise MusicError(ErrorCode.MUSIC_FORBIDDEN, "只有房主可以清空队列")
        if self.is_empty:
            return
        self.queue.clear()
        self.current = None
        self.revision += 1

    def report_eos(self, *, entry_id: str, revision: int, now: int) -> bool:
        """客户端上报「本机放完了」。

        revision 不匹配说明这一轮已经推进过（别的客户端先报了，或 tick 先到了）：
        直接忽略，保证幂等。
        """
        current = self.current
        if current is None or current.entry_id != entry_id or revision != self.revision:
            return False
        self._advance(now)
        return True

    def tick(self, now: int) -> bool:
        """按时间推进：到了该切歌的时刻就切。返回是否发生了变化。"""
        current = self.current
        if current is None:
            if not self.queue:
                return False
            self._ensure_started(now)
            self.revision += 1
            return True
        if not current.playing:
            return False
        duration = current.duration_ms
        if duration is None:
            due = current.anchor_server_ms + UNKNOWN_DURATION_CAP_MS
        else:
            remaining = max(0, duration - current.anchor_position_ms)
            due = current.anchor_server_ms + remaining + END_GRACE_MS
        if now < due:
            return False
        self._advance(now)
        return True

    def reset(self) -> None:
        """房间回收 / 进房快照重建时的清空（保留 revision 单调性无意义，直接归零）。"""
        self.revision = 0
        self.current = None
        self.queue.clear()
        self._seq = 0
        self._last_enqueue_ms.clear()

    # ------------------------------------------------------------------ 内部
    def _check_current_control(self, *, peer_id: str, is_owner: bool) -> None:
        current = self.current
        if current is None:
            raise MusicError(ErrorCode.MUSIC_NOT_FOUND, "现在没有正在播放的歌")
        if not is_owner and current.requested_by.peer_id != peer_id:
            raise MusicError(ErrorCode.MUSIC_FORBIDDEN, "只有房主或点歌人可以切歌")

    def _ensure_started(self, now: int) -> None:
        if self.current is not None or not self.queue:
            return
        self._start_next(now)

    def _advance(self, now: int) -> None:
        self._start_next(now)
        self.revision += 1

    def _start_next(self, now: int) -> None:
        self.current = None
        if not self.queue:
            return
        entry = self.queue.pop(0)
        self.current = MusicCurrent(
            entry_id=entry.entry_id,
            source=entry.source,
            song_id=entry.song_id,
            music_info=entry.music_info,
            title=entry.title,
            artist=entry.artist,
            duration_ms=entry.duration_ms,
            requested_by=entry.requested_by,
            requested_at_ms=entry.requested_at_ms,
            playing=True,
            anchor_server_ms=now + PREROLL_MS,
            anchor_position_ms=0,
        )

    def _entries(self) -> list[MusicEntry]:
        current = self.current
        return ([current] if current is not None else []) + self.queue

    def _mine_count(self, peer_id: str) -> int:
        return sum(1 for item in self._entries() if item.requested_by.peer_id == peer_id)
