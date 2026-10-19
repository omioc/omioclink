"""房间点歌状态机（纯内存，不经 WebSocket）。

覆盖：点歌上限与冷却、锚点与 tick 推进、EOS 幂等、权限（本人 / 房主）、清空。
"""

from __future__ import annotations

import pytest

from app.signaling.music import (
    END_GRACE_MS,
    MAX_MUSIC_INFO_BYTES,
    MAX_QUEUE_SIZE,
    PER_USER_QUEUE_LIMIT,
    PREROLL_MS,
    UNKNOWN_DURATION_CAP_MS,
    MusicError,
    RoomMusic,
)
from app.signaling.protocol import ErrorCode


def _enqueue(
    music: RoomMusic,
    *,
    peer_id: str = "p1",
    song_id: str = "1",
    now: int = 0,
    duration_ms: int | None = 180_000,
) -> None:
    music.enqueue(
        peer_id=peer_id,
        display_name=f"用户{peer_id}",
        source="kugou",
        song_id=song_id,
        music_info={"id": song_id, "title": f"歌{song_id}"},
        title=f"歌{song_id}",
        artist="歌手",
        duration_ms=duration_ms,
        now=now,
    )


def test_first_enqueue_becomes_current_with_preroll_anchor() -> None:
    music = RoomMusic()

    _enqueue(music, now=1_000)

    current = music.current
    assert current is not None
    assert current.entry_id == "e1"
    assert current.title == "歌1"
    assert current.playing is True
    # 预滚：锚点比「现在」晚 PREROLL，客户端靠这段时间解析直链并缓冲
    assert current.anchor_server_ms == 1_000 + PREROLL_MS
    assert current.anchor_position_ms == 0
    assert music.queue == []
    assert music.revision == 1


def test_queue_order_and_per_user_limit() -> None:
    music = RoomMusic()
    _enqueue(music, peer_id="p1", song_id="1", now=0)
    _enqueue(music, peer_id="p2", song_id="2", now=0)
    _enqueue(music, peer_id="p2", song_id="3", now=20_000)

    assert [item.song_id for item in music.queue] == ["2", "3"]
    # p2 已经有 2 首（队列里两首，当前曲是 p1 的）
    with pytest.raises(MusicError) as info:
        _enqueue(music, peer_id="p2", song_id="4", now=40_000)
    assert info.value.code == ErrorCode.MUSIC_QUEUE_FULL
    assert str(PER_USER_QUEUE_LIMIT) in info.value.message


def test_enqueue_cooldown() -> None:
    music = RoomMusic()
    _enqueue(music, peer_id="p1", song_id="1", now=0)

    with pytest.raises(MusicError) as info:
        _enqueue(music, peer_id="p1", song_id="2", now=1_000)
    assert info.value.code == ErrorCode.MUSIC_RATE_LIMITED

    # 冷却过后可以点（此时第一首已不再占「每人 2 首」的名额以外的位置）
    _enqueue(music, peer_id="p1", song_id="2", now=10_000)
    assert music.queue[0].song_id == "2"
def test_queue_size_limit() -> None:
    music = RoomMusic()
    # 用不同 peer 绕开「每人 2 首」限制，只看队列总上限
    for index in range(MAX_QUEUE_SIZE + 1):
        _enqueue(music, peer_id=f"p{index}", song_id=str(index), now=0)
    assert len(music.queue) == MAX_QUEUE_SIZE  # 第一首成了当前曲

    with pytest.raises(MusicError) as info:
        _enqueue(music, peer_id="p999", song_id="x", now=0)
    assert info.value.code == ErrorCode.MUSIC_QUEUE_FULL


def test_duplicate_song_and_oversized_music_info() -> None:
    music = RoomMusic()
    _enqueue(music, song_id="1", now=0)
    with pytest.raises(MusicError) as info:
        _enqueue(music, peer_id="p2", song_id="1", now=0)
    assert info.value.code == ErrorCode.MUSIC_INVALID_ENTRY

    big = RoomMusic()
    with pytest.raises(MusicError) as info:
        big.enqueue(
            peer_id="p1",
            display_name="A",
            source="kugou",
            song_id="9",
            music_info={"blob": "x" * (MAX_MUSIC_INFO_BYTES + 10)},
            title="t",
            artist="a",
            duration_ms=1_000,
            now=0,
        )
    assert info.value.code == ErrorCode.MUSIC_INVALID_ENTRY


def test_tick_advances_when_duration_elapsed() -> None:
    music = RoomMusic()
    _enqueue(music, song_id="1", now=0, duration_ms=10_000)
    _enqueue(music, peer_id="p2", song_id="2", now=0, duration_ms=10_000)

    start = PREROLL_MS
    assert music.tick(start + 10_000) is False, "还没到宽限期"
    assert music.tick(start + 10_000 + END_GRACE_MS) is True

    current = music.current
    assert current is not None and current.song_id == "2"
    assert current.anchor_server_ms == start + 10_000 + END_GRACE_MS + PREROLL_MS
    assert music.revision == 3


def test_tick_with_unknown_duration_uses_cap() -> None:
    music = RoomMusic()
    _enqueue(music, song_id="1", now=0, duration_ms=None)

    assert music.tick(PREROLL_MS + 60_000) is False
    assert music.tick(PREROLL_MS + UNKNOWN_DURATION_CAP_MS) is True
    assert music.current is None, "队列空了，current 也该清掉"


def test_position_ms_respects_anchor_and_duration() -> None:
    music = RoomMusic()
    _enqueue(music, song_id="1", now=0, duration_ms=10_000)

    assert music.position_ms(PREROLL_MS - 1) == 0, "锚点之前不算进度"
    assert music.position_ms(PREROLL_MS + 2_000) == 2_000
    assert music.position_ms(PREROLL_MS + 99_000) == 10_000, "不能超过时长"


def test_eos_is_idempotent_and_needs_matching_revision() -> None:
    music = RoomMusic()
    _enqueue(music, song_id="1", now=0)
    _enqueue(music, peer_id="p2", song_id="2", now=0)

    revision = music.revision
    assert music.report_eos(entry_id="e1", revision=revision - 1, now=5_000) is False
    assert music.report_eos(entry_id="e2", revision=revision, now=5_000) is False

    assert music.report_eos(entry_id="e1", revision=revision, now=5_000) is True
    assert music.current is not None and music.current.song_id == "2"
    # 重复上报（别的客户端慢半拍）不能又切一首
    assert music.report_eos(entry_id="e1", revision=revision, now=5_001) is False
    assert music.current is not None and music.current.song_id == "2"


def test_remove_permissions() -> None:
    music = RoomMusic()
    _enqueue(music, peer_id="p1", song_id="1", now=0)
    _enqueue(music, peer_id="p2", song_id="2", now=0)
    second = music.queue[0]

    with pytest.raises(MusicError) as info:
        music.remove(peer_id="p1", is_owner=False, entry_id=second.entry_id, now=1)
    assert info.value.code == ErrorCode.MUSIC_FORBIDDEN

    music.remove(peer_id="p1", is_owner=True, entry_id=second.entry_id, now=1)
    assert music.queue == []

    with pytest.raises(MusicError) as info:
        music.remove(peer_id="p1", is_owner=False, entry_id="e404", now=1)
    assert info.value.code == ErrorCode.MUSIC_NOT_FOUND


def test_remove_current_acts_like_skip() -> None:
    music = RoomMusic()
    _enqueue(music, peer_id="p1", song_id="1", now=0)
    _enqueue(music, peer_id="p2", song_id="2", now=0)

    music.remove(peer_id="p1", is_owner=False, entry_id="e1", now=1_000)

    assert music.current is not None and music.current.song_id == "2"


def test_skip_permissions() -> None:
    music = RoomMusic()
    _enqueue(music, peer_id="p1", song_id="1", now=0)
    _enqueue(music, peer_id="p2", song_id="2", now=0)

    with pytest.raises(MusicError) as info:
        music.skip(peer_id="p2", is_owner=False, entry_id=None, now=1)
    assert info.value.code == ErrorCode.MUSIC_FORBIDDEN

    # 点歌人本人可以切
    music.skip(peer_id="p1", is_owner=False, entry_id="e1", now=2)
    assert music.current is not None and music.current.song_id == "2"

    # 房主可以切别人的歌
    music.skip(peer_id="owner", is_owner=True, entry_id=None, now=3)
    assert music.current is None


def test_clear_requires_owner() -> None:
    music = RoomMusic()
    _enqueue(music, peer_id="p1", song_id="1", now=0)
    _enqueue(music, peer_id="p2", song_id="2", now=0)

    with pytest.raises(MusicError) as info:
        music.clear(is_owner=False)
    assert info.value.code == ErrorCode.MUSIC_FORBIDDEN

    before = music.revision
    music.clear(is_owner=True)
    assert music.current is None
    assert music.queue == []
    assert music.revision == before + 1
