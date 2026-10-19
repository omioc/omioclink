"""房间点歌状态机（纯内存，不经 WebSocket）。

覆盖：点歌上限与冷却、锚点与 tick 推进、EOS 幂等、权限（本人 / 房主）、清空。
"""

from __future__ import annotations

import random

import pytest

from app.signaling.music import (
    DEFAULT_MUSIC_MODE,
    END_GRACE_MS,
    ENQUEUE_COOLDOWN_MS,
    MAX_MUSIC_INFO_BYTES,
    MAX_QUEUE_SIZE,
    MUSIC_MODE_REPEAT_ALL,
    MUSIC_MODE_REPEAT_ONE,
    MUSIC_MODE_SEQUENTIAL,
    MUSIC_MODE_SHUFFLE,
    PER_USER_QUEUE_LIMIT,
    PREROLL_MS,
    UNKNOWN_DURATION_CAP_MS,
    EnqueueRequest,
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


def test_queue_order_follows_enqueue_time() -> None:
    music = RoomMusic()
    _enqueue(music, peer_id="p1", song_id="1", now=0)
    _enqueue(music, peer_id="p2", song_id="2", now=0)
    _enqueue(music, peer_id="p2", song_id="3", now=20_000)

    assert [item.song_id for item in music.queue] == ["2", "3"]


def test_per_user_limit() -> None:
    music = RoomMusic()
    # 冷却按人算：同一个人的 N 首歌之间要各自错开 ENQUEUE_COOLDOWN_MS
    for index in range(PER_USER_QUEUE_LIMIT):
        _enqueue(
            music,
            peer_id="p1",
            song_id=str(index),
            now=index * ENQUEUE_COOLDOWN_MS,
        )
    # 名额含正在播的那首：自己占满时 size 正好等于上限
    assert music.size == PER_USER_QUEUE_LIMIT
    assert music.current is not None
    assert music.current.requested_by.peer_id == "p1"

    with pytest.raises(MusicError) as info:
        _enqueue(
            music,
            peer_id="p1",
            song_id="extra",
            now=PER_USER_QUEUE_LIMIT * ENQUEUE_COOLDOWN_MS,
        )
    assert info.value.code == ErrorCode.MUSIC_QUEUE_FULL
    assert str(PER_USER_QUEUE_LIMIT) in info.value.message

    # 别人不占同一份名额
    _enqueue(music, peer_id="p2", song_id="other", now=1_000)
    assert len(music.queue) == PER_USER_QUEUE_LIMIT


def test_enqueue_cooldown() -> None:
    music = RoomMusic()
    _enqueue(music, peer_id="p1", song_id="1", now=0)

    with pytest.raises(MusicError) as info:
        _enqueue(music, peer_id="p1", song_id="2", now=ENQUEUE_COOLDOWN_MS - 1)
    assert info.value.code == ErrorCode.MUSIC_RATE_LIMITED

    # 冷却走完就能再点（下限是毫秒级的 ENQUEUE_COOLDOWN_MS，不再按 10 秒算）
    _enqueue(music, peer_id="p1", song_id="2", now=ENQUEUE_COOLDOWN_MS)
    assert music.queue[0].song_id == "2"


def test_queue_size_limit() -> None:
    music = RoomMusic()
    # 用不同 peer 绕开「每人 88 首」限制，只看队列总上限
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


def _batch(
    music: RoomMusic,
    *,
    peer_id: str = "p1",
    count: int,
    now: int,
    start: int = 0,
) -> list[str]:
    added = music.enqueue_many(
        peer_id=peer_id,
        display_name=f"用户{peer_id}",
        requests=[
            EnqueueRequest(
                source="kugou",
                song_id=str(index),
                music_info={"id": str(index)},
                title=f"歌{index}",
            )
            for index in range(start, start + count)
        ],
        now=now,
    )
    return [entry.song_id for entry in added]


def test_enqueue_many_is_one_request() -> None:
    music = RoomMusic()

    assert _batch(music, count=3, now=0) == ["0", "1", "2"]
    # 一批只算一次请求：revision 只加一次，当前曲就是第一首
    assert music.revision == 1
    assert music.current is not None and music.current.song_id == "0"

    # 冷却按批算：2 秒内再来一批直接拒，不会一半进一半被拦
    with pytest.raises(MusicError) as info:
        _batch(music, count=3, now=ENQUEUE_COOLDOWN_MS - 1, start=10)
    assert info.value.code == ErrorCode.MUSIC_RATE_LIMITED

    # 冷却过后整批照收
    assert _batch(music, count=2, now=ENQUEUE_COOLDOWN_MS, start=20) == ["20", "21"]


def test_enqueue_many_stops_at_per_user_quota() -> None:
    music = RoomMusic()

    added = _batch(music, count=PER_USER_QUEUE_LIMIT + 5, now=0)

    assert len(added) == PER_USER_QUEUE_LIMIT
    assert music.size == PER_USER_QUEUE_LIMIT


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
    # 顺序播放：一首放完就停，才能看清 cap 生效；列表循环会把它重新排起来
    music.set_mode(MUSIC_MODE_SEQUENTIAL)
    _enqueue(music, song_id="1", now=0, duration_ms=None)

    assert music.tick(PREROLL_MS + 60_000) is False
    assert music.tick(PREROLL_MS + UNKNOWN_DURATION_CAP_MS) is True
    assert music.current is None, "队列空了，current 也该清掉"


def test_default_mode_is_repeat_all() -> None:
    music = RoomMusic()
    assert music.mode == DEFAULT_MUSIC_MODE
    assert music.mode == MUSIC_MODE_REPEAT_ALL
    assert music.snapshot(0).mode == MUSIC_MODE_REPEAT_ALL


def test_set_mode_bumps_revision_once() -> None:
    music = RoomMusic()
    music.set_mode(MUSIC_MODE_SEQUENTIAL)
    assert music.revision == 1
    # 同一个模式再点一次：不折腾快照，也不打扰正在播的歌
    music.set_mode(MUSIC_MODE_SEQUENTIAL)
    assert music.revision == 1
    with pytest.raises(MusicError):
        music.set_mode("nope")


def test_repeat_one_restarts_same_song() -> None:
    music = RoomMusic()
    _enqueue(music, song_id="1", now=0, duration_ms=10_000)
    _enqueue(music, peer_id="p2", song_id="2", now=0, duration_ms=10_000)
    music.set_mode(MUSIC_MODE_REPEAT_ONE)

    current = music.current
    assert current is not None
    due = current.anchor_server_ms + 10_000 + END_GRACE_MS
    assert music.tick(due) is True

    again = music.current
    assert again is not None and again.song_id == "1", "单曲循环：还是这首"
    # 换锚点重来：客户端靠 anchorServerMs 变化重新起播
    assert again.anchor_server_ms == due + PREROLL_MS
    assert [item.song_id for item in music.queue] == ["2"], "队列不该被消耗"


def test_sequential_stops_when_queue_ends() -> None:
    music = RoomMusic()
    music.set_mode(MUSIC_MODE_SEQUENTIAL)
    _enqueue(music, song_id="1", now=0, duration_ms=10_000)

    current = music.current
    assert current is not None
    assert music.tick(current.anchor_server_ms + 10_000 + END_GRACE_MS) is True
    assert music.current is None


def test_repeat_all_replays_whole_round() -> None:
    music = RoomMusic()
    _enqueue(music, song_id="1", now=0, duration_ms=10_000)
    _enqueue(music, peer_id="p2", song_id="2", now=0, duration_ms=10_000)

    first = music.current
    assert first is not None and first.song_id == "1"
    assert music.tick(first.anchor_server_ms + 10_000 + END_GRACE_MS) is True
    second = music.current
    assert second is not None and second.song_id == "2"

    assert music.tick(second.anchor_server_ms + 10_000 + END_GRACE_MS) is True
    # 一轮播完：按原顺序把这一轮重新排一遍
    restarted = music.current
    assert restarted is not None and restarted.song_id == "1"
    assert [item.song_id for item in music.queue] == ["2"]


def test_shuffle_plays_every_entry_once() -> None:
    music = RoomMusic(_rng=random.Random(7))
    music.set_mode(MUSIC_MODE_SHUFFLE)
    for index, peer in enumerate(["p1", "p2", "p3"]):
        _enqueue(music, peer_id=peer, song_id=str(index), now=0)

    first = music.current
    assert first is not None
    played = [first.song_id]
    for _ in range(2):
        current = music.current
        assert current is not None
        assert music.tick(current.anchor_server_ms + 180_000 + END_GRACE_MS) is True
        following = music.current
        assert following is not None
        played.append(following.song_id)

    # 随机的是顺序，不是重复：「三首各播一次」
    assert sorted(played) == ["0", "1", "2"]


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
