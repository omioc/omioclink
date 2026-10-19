"""``SignalingState`` 纯状态层单元测试（不涉及 I/O，跑得飞快）。"""

from datetime import UTC, datetime, timedelta

from app.signaling.state import Peer, RoomRecord, SignalingState


class FakeChannel:
    """满足 ``PeerChannel`` 协议的内存实现。"""

    def __init__(self) -> None:
        self.sent: list[str] = []
        self.closed: list[tuple[int, str | None]] = []

    async def send_text(self, data: str) -> None:
        self.sent.append(data)

    async def close(self, code: int = 1000, reason: str | None = None) -> None:
        self.closed.append((code, reason))


def room_record(room_id: str = "ROOM01", *, capacity: int = 5, name: str = "游戏开黑") -> RoomRecord:
    return RoomRecord(
        room_id=room_id,
        name=name,
        owner_id=1,
        capacity=capacity,
        has_password=False,
        password_hash=None,
        is_public=True,
        created_at=datetime(2026, 1, 1, tzinfo=UTC),
    )


def add_peer(
    state: SignalingState,
    *,
    user_id: int = 1,
    username: str = "alice",
    joined_at: datetime | None = None,
) -> Peer:
    peer = Peer(
        peer_id=state.new_peer_id(),
        user_id=user_id,
        username=username,
        display_name=username,
        avatar=None,
        channel=FakeChannel(),
    )
    if joined_at is not None:
        peer.joined_at = joined_at
    state.add_peer(peer)
    return peer


def join(state: SignalingState, peer: Peer, room_id: str = "ROOM01") -> None:
    room = state.ensure_room(room_record(room_id))
    room.peers[peer.peer_id] = peer
    peer.room_id = room_id


def test_peer_ids_are_unique_and_session_scoped() -> None:
    state = SignalingState()
    peers = [add_peer(state) for _ in range(50)]
    assert len({peer.peer_id for peer in peers}) == 50
    assert all(len(peer.peer_id) == 8 for peer in peers)


def test_remove_peer_detaches_it_from_its_room() -> None:
    """回归：remove_peer 曾先摘索引再离房，导致掉线者永远留在房间成员表里。"""
    state = SignalingState()
    alice = add_peer(state, user_id=1, username="alice")
    bob = add_peer(state, user_id=2, username="bob")
    join(state, alice)
    join(state, bob)

    room = state.get_room("ROOM01")
    assert room is not None
    assert room.member_count == 2

    state.remove_peer(bob.peer_id)

    room = state.get_room("ROOM01")
    assert room is not None
    assert room.member_count == 1
    assert [member.peer_id for member in room.member_infos()] == [alice.peer_id]
    assert bob.room_id is None


def test_removing_the_last_member_reclaims_the_room() -> None:
    state = SignalingState()
    peer = add_peer(state)
    join(state, peer)
    assert state.live_room_count == 1

    state.remove_peer(peer.peer_id)

    assert state.get_room("ROOM01") is None
    assert state.live_room_count == 0
    assert state.live_member_count("ROOM01") == 0


def test_leave_room_keeps_the_session_registered() -> None:
    state = SignalingState()
    peer = add_peer(state)
    join(state, peer)

    assert state.leave_room(peer.peer_id) is None  # 房间空了 → 被回收

    assert peer.room_id is None
    assert state.get_peer(peer.peer_id) is peer
    assert state.is_user_online(peer.user_id) is True


def test_user_index_tracks_sessions_and_duplicates() -> None:
    state = SignalingState()
    first = add_peer(state, user_id=7, username="alice")
    second = add_peer(state, user_id=7, username="alice")

    assert {peer.peer_id for peer in state.peers_of_user(7)} == {first.peer_id, second.peer_id}
    assert state.online_user_ids() == {7}

    state.remove_peer(first.peer_id)
    assert [peer.peer_id for peer in state.peers_of_user(7)] == [second.peer_id]

    state.remove_peer(second.peer_id)
    assert state.peers_of_user(7) == []
    assert state.is_user_online(7) is False
    assert state.online_user_ids() == set()


def test_remove_unknown_peer_is_a_noop() -> None:
    state = SignalingState()
    assert state.remove_peer("deadbeef") is None


def test_member_infos_are_ordered_by_join_time() -> None:
    state = SignalingState()
    base = datetime(2026, 5, 1, 12, 0, tzinfo=UTC)
    late = add_peer(state, user_id=3, username="carol", joined_at=base + timedelta(seconds=20))
    early = add_peer(state, user_id=1, username="alice", joined_at=base)
    middle = add_peer(state, user_id=2, username="bob", joined_at=base + timedelta(seconds=10))
    for peer in (late, early, middle):
        join(state, peer)

    room = state.get_room("ROOM01")
    assert room is not None
    assert [member.username for member in room.member_infos()] == ["alice", "bob", "carol"]


def test_ensure_room_follows_metadata_changes() -> None:
    state = SignalingState()
    peer = add_peer(state)
    join(state, peer)

    state.ensure_room(room_record(name="改名后的房间", capacity=3))

    room = state.get_room("ROOM01")
    assert room is not None
    assert room.name == "改名后的房间"
    assert room.capacity == 3
    assert room.member_count == 1  # 成员不会被元数据刷新清掉


def test_sharer_is_reported_from_member_state() -> None:
    state = SignalingState()
    alice = add_peer(state, user_id=1, username="alice")
    bob = add_peer(state, user_id=2, username="bob")
    join(state, alice)
    join(state, bob)

    room = state.get_room("ROOM01")
    assert room is not None
    assert room.sharer_peer_id is None

    bob.sharing = True
    assert room.sharer_peer_id == bob.peer_id


def test_member_info_snapshot_uses_aliases() -> None:
    state = SignalingState()
    peer = add_peer(state, user_id=9, username="alice")
    join(state, peer)
    room = state.get_room("ROOM01")
    assert room is not None

    payload = room.member_infos()[0].model_dump(by_alias=True)
    assert payload["peerId"] == peer.peer_id
    assert payload["userId"] == 9
    assert payload["displayName"] == "alice"
    assert payload["muted"] is False
    assert payload["sharing"] is False
