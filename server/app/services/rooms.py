"""房间服务（持久化的房间元数据 + 进房历史）。"""

import secrets
from collections.abc import Sequence
from datetime import UTC, datetime

from sqlalchemy import delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.security import hash_password
from app.db.models import Room, RoomMembership, User
from app.signaling.state import RoomRecord

__all__ = [
    "ROOM_ID_ALPHABET",
    "ROOM_ID_LENGTH",
    "CountMap",
    "count_members",
    "count_rooms",
    "create_room",
    "delete_room",
    "generate_room_id",
    "get_room",
    "list_all_rooms",
    "list_public_rooms",
    "list_user_rooms",
    "owner_names",
    "to_record",
    "touch_membership",
    "update_room",
]

#: 去除易混淆字符（0/O、1/I）的房间码字母表
ROOM_ID_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
ROOM_ID_LENGTH = 6
_ID_MAX_ATTEMPTS = 16

CountMap = dict[str, int]


def generate_room_id() -> str:
    return "".join(secrets.choice(ROOM_ID_ALPHABET) for _ in range(ROOM_ID_LENGTH))


async def _room_id_exists(session: AsyncSession, room_id: str) -> bool:
    return await session.get(Room, room_id) is not None


async def create_room(
    session: AsyncSession,
    *,
    owner: User,
    name: str,
    capacity: int,
    password: str | None,
    is_public: bool,
    settings: Settings,
) -> Room:
    room_id = generate_room_id()
    for _ in range(_ID_MAX_ATTEMPTS):
        if not await _room_id_exists(session, room_id):
            break
        room_id = generate_room_id()

    room = Room(
        id=room_id,
        name=name,
        owner_id=owner.id,
        capacity=min(max(capacity, 2), settings.room_capacity_ceiling),
        has_password=bool(password),
        password_hash=hash_password(password) if password else None,
        is_public=is_public,
    )
    session.add(room)
    await session.flush()
    return room


async def get_room(session: AsyncSession, room_id: str) -> Room | None:
    return await session.get(Room, room_id)


async def list_public_rooms(
    session: AsyncSession, *, limit: int = 50, offset: int = 0
) -> Sequence[Room]:
    result = await session.execute(
        select(Room)
        .where(Room.is_public.is_(True))
        .order_by(Room.updated_at.desc(), Room.created_at.desc())
        .limit(limit)
        .offset(offset)
    )
    return result.scalars().all()


async def list_user_rooms(
    session: AsyncSession, *, user_id: int, limit: int = 50, offset: int = 0
) -> Sequence[Room]:
    member_room_ids = select(RoomMembership.room_id).where(RoomMembership.user_id == user_id)
    result = await session.execute(
        select(Room)
        .where(or_(Room.owner_id == user_id, Room.id.in_(member_room_ids)))
        .order_by(Room.updated_at.desc(), Room.created_at.desc())
        .limit(limit)
        .offset(offset)
    )
    return result.scalars().all()


async def update_room(
    session: AsyncSession,
    room: Room,
    *,
    name: str | None = None,
    capacity: int | None = None,
    is_public: bool | None = None,
    settings: Settings,
) -> Room:
    if name is not None:
        room.name = name
    if capacity is not None:
        room.capacity = min(max(capacity, 2), settings.room_capacity_ceiling)
    if is_public is not None:
        room.is_public = is_public
    room.updated_at = datetime.now(UTC)
    await session.flush()
    return room


async def delete_room(session: AsyncSession, room: Room) -> None:
    await session.execute(delete(Room).where(Room.id == room.id))


async def touch_membership(session: AsyncSession, room_id: str, user_id: int) -> None:
    """记录「用户进过这个房间」，用于「我的房间」列表。"""
    result = await session.execute(
        select(RoomMembership).where(
            RoomMembership.room_id == room_id, RoomMembership.user_id == user_id
        )
    )
    membership = result.scalar_one_or_none()
    now = datetime.now(UTC)
    if membership is None:
        session.add(
            RoomMembership(room_id=room_id, user_id=user_id, joined_at=now, last_joined_at=now)
        )
    else:
        membership.last_joined_at = now
    await session.flush()


async def list_all_rooms(
    session: AsyncSession, *, limit: int = 100, offset: int = 0
) -> Sequence[Room]:
    """管理端用：列出**全部**房间（含私有房间）。"""
    result = await session.execute(
        select(Room)
        .order_by(Room.updated_at.desc(), Room.created_at.desc())
        .limit(limit)
        .offset(offset)
    )
    return result.scalars().all()


async def count_rooms(session: AsyncSession, *, public_only: bool = False) -> int:
    statement = select(func.count(Room.id))
    if public_only:
        statement = statement.where(Room.is_public.is_(True))
    result = await session.execute(statement)
    return int(result.scalar_one())


async def owner_names(session: AsyncSession, rooms: Sequence[Room]) -> dict[int, str]:
    owner_ids = {room.owner_id for room in rooms}
    if not owner_ids:
        return {}
    result = await session.execute(
        select(User.id, User.display_name).where(User.id.in_(owner_ids))
    )
    return {int(user_id): name for user_id, name in result.all()}


async def count_members(session: AsyncSession, room_ids: Sequence[str]) -> CountMap:
    if not room_ids:
        return {}
    result = await session.execute(
        select(RoomMembership.room_id, func.count(RoomMembership.id))
        .where(RoomMembership.room_id.in_(room_ids))
        .group_by(RoomMembership.room_id)
    )
    return {room_id: int(count) for room_id, count in result.all()}


def to_record(room: Room) -> RoomRecord:
    return RoomRecord(
        room_id=room.id,
        name=room.name,
        owner_id=room.owner_id,
        capacity=room.capacity,
        has_password=room.has_password,
        password_hash=room.password_hash,
        is_public=room.is_public,
        created_at=room.created_at,
    )
