"""好友服务。

约定：``accepted`` 的好友关系在库中存**双向两行**（``user → friend`` 与 ``friend → user``），
``pending`` 只存一行（申请人 → 被申请人）。
"""

from collections.abc import Sequence
from typing import Any, cast

from sqlalchemy import CursorResult, delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.i18n import t
from app.db.models import Friendship, FriendshipStatus, User

__all__ = [
    "cancel_request",
    "list_friends",
    "list_incoming_requests",
    "list_outgoing_requests",
    "remove_friend",
    "respond_request",
    "send_request",
]


async def _find(session: AsyncSession, user_id: int, friend_id: int) -> Friendship | None:
    result = await session.execute(
        select(Friendship).where(
            Friendship.user_id == user_id, Friendship.friend_id == friend_id
        )
    )
    return result.scalar_one_or_none()


async def list_friends(session: AsyncSession, user_id: int) -> Sequence[User]:
    result = await session.execute(
        select(User)
        .join(Friendship, Friendship.friend_id == User.id)
        .where(Friendship.user_id == user_id, Friendship.status == FriendshipStatus.ACCEPTED)
        .order_by(User.display_name)
    )
    return result.scalars().all()


async def list_incoming_requests(session: AsyncSession, user_id: int) -> Sequence[Friendship]:
    result = await session.execute(
        select(Friendship)
        .where(
            Friendship.friend_id == user_id,
            Friendship.status == FriendshipStatus.PENDING,
        )
        .order_by(Friendship.created_at.desc())
    )
    return result.scalars().all()


async def list_outgoing_requests(session: AsyncSession, user_id: int) -> Sequence[Friendship]:
    result = await session.execute(
        select(Friendship)
        .where(
            Friendship.user_id == user_id,
            Friendship.status == FriendshipStatus.PENDING,
        )
        .order_by(Friendship.created_at.desc())
    )
    return result.scalars().all()


async def send_request(
    session: AsyncSession, *, requester: User, target: User
) -> Friendship:
    """发起好友申请；若对方已向我发起，则直接互加。"""
    if requester.id == target.id:
        raise ValueError(t("friends.cannot_add_self"))

    existing = await _find(session, requester.id, target.id)
    if existing is not None and existing.status == FriendshipStatus.ACCEPTED:
        raise AlreadyFriendsError
    if existing is not None and existing.status == FriendshipStatus.PENDING:
        raise DuplicateRequestError

    reverse = await _find(session, target.id, requester.id)
    if reverse is not None and reverse.status == FriendshipStatus.PENDING:
        # 双向奔赴：直接成为好友。返回朝向申请人的那一行，
        # 这样响应里的 direction 才是申请人视角的 outgoing。
        await _accept(session, reverse)
        forward = await _find(session, requester.id, target.id)
        return forward if forward is not None else reverse

    request = Friendship(
        user_id=requester.id, friend_id=target.id, status=FriendshipStatus.PENDING
    )
    session.add(request)
    await session.flush()
    return request


async def respond_request(
    session: AsyncSession, *, user_id: int, request_id: int, accept: bool
) -> Friendship | None:
    request = await session.get(Friendship, request_id)
    if (
        request is None
        or request.friend_id != user_id
        or request.status != FriendshipStatus.PENDING
    ):
        return None
    if not accept:
        await session.execute(delete(Friendship).where(Friendship.id == request.id))
        await session.flush()
        return None
    return await _accept(session, request)


async def _accept(session: AsyncSession, request: Friendship) -> Friendship:
    request.status = FriendshipStatus.ACCEPTED
    reverse = await _find(session, request.friend_id, request.user_id)
    if reverse is None:
        session.add(
            Friendship(
                user_id=request.friend_id,
                friend_id=request.user_id,
                status=FriendshipStatus.ACCEPTED,
            )
        )
    else:
        reverse.status = FriendshipStatus.ACCEPTED
    await session.flush()
    return request


async def cancel_request(session: AsyncSession, *, user_id: int, request_id: int) -> bool:
    request = await session.get(Friendship, request_id)
    if request is None or request.user_id != user_id or request.status != FriendshipStatus.PENDING:
        return False
    await session.execute(delete(Friendship).where(Friendship.id == request.id))
    await session.flush()
    return True


async def remove_friend(session: AsyncSession, *, user_id: int, friend_id: int) -> bool:
    result = cast(
        CursorResult[Any],
        await session.execute(
            delete(Friendship).where(
                Friendship.user_id.in_([user_id, friend_id]),
                Friendship.friend_id.in_([user_id, friend_id]),
            )
        ),
    )
    await session.flush()
    return bool(result.rowcount)


class AlreadyFriendsError(Exception):
    """已经是好友。"""


class DuplicateRequestError(Exception):
    """已存在待处理的好友申请。"""
