"""好友接口：列表、申请、同意/拒绝、删除。

在线状态来自信令层的内存状态（Presence），不落库。
"""

from fastapi import APIRouter, Response, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import CurrentUser, HubDep, SessionDep
from app.api.serializers import user_profile
from app.core.errors import ConflictError, NotFoundError, ValidationError
from app.db.models import Friendship, User
from app.schemas import (
    FriendListResponse,
    FriendRequestAction,
    FriendRequestCreate,
    FriendRequestListResponse,
    FriendRequestResponse,
    FriendResponse,
)
from app.services import accounts
from app.services import friends as friend_service
from app.signaling.hub import SignalingHub

router = APIRouter(prefix="/friends", tags=["好友"])


async def _request_user(session: AsyncSession, request: Friendship, viewer_id: int) -> User | None:
    other_id = request.friend_id if request.user_id == viewer_id else request.user_id
    return await accounts.get_user(session, other_id)


def _request_response(
    request: Friendship, other: User, *, viewer_id: int, hub: SignalingHub
) -> FriendRequestResponse:
    return FriendRequestResponse(
        id=request.id,
        user=user_profile(other, online=hub.state.is_user_online(other.id)),
        direction="outgoing" if request.user_id == viewer_id else "incoming",
        created_at=request.created_at,
    )


@router.get("", response_model=FriendListResponse, summary="好友列表")
async def list_friends(
    user: CurrentUser, session: SessionDep, hub: HubDep
) -> FriendListResponse:
    friends = await friend_service.list_friends(session, user.id)
    items = [
        FriendResponse(
            user=user_profile(friend, online=hub.state.is_user_online(friend.id)),
            online=hub.state.is_user_online(friend.id),
        )
        for friend in friends
    ]
    return FriendListResponse(items=items, total=len(items))


@router.get(
    "/requests", response_model=FriendRequestListResponse, summary="好友申请（收发双向）"
)
async def list_requests(
    user: CurrentUser, session: SessionDep, hub: HubDep
) -> FriendRequestListResponse:
    incoming = await friend_service.list_incoming_requests(session, user.id)
    outgoing = await friend_service.list_outgoing_requests(session, user.id)
    items: list[FriendRequestResponse] = []
    for request in incoming:
        other = await accounts.get_user(session, request.user_id)
        if other is not None:
            items.append(_request_response(request, other, viewer_id=user.id, hub=hub))
    for request in outgoing:
        other = await accounts.get_user(session, request.friend_id)
        if other is not None:
            items.append(_request_response(request, other, viewer_id=user.id, hub=hub))
    return FriendRequestListResponse(items=items, total=len(items))


@router.post(
    "/requests",
    response_model=FriendRequestResponse,
    status_code=status.HTTP_201_CREATED,
    summary="发起好友申请",
)
async def create_request(
    payload: FriendRequestCreate, user: CurrentUser, session: SessionDep, hub: HubDep
) -> FriendRequestResponse:
    target = await accounts.get_user_by_username(session, payload.username)
    if target is None:
        raise NotFoundError("用户不存在", code="user_not_found")
    try:
        request = await friend_service.send_request(session, requester=user, target=target)
    except ValueError as exc:
        raise ValidationError(str(exc)) from exc
    except friend_service.AlreadyFriendsError as exc:
        raise ConflictError("你们已经是好友", code="already_friends") from exc
    except friend_service.DuplicateRequestError as exc:
        raise ConflictError("已发送过申请，等待对方处理", code="duplicate_request") from exc
    return _request_response(request, target, viewer_id=user.id, hub=hub)


@router.post(
    "/requests/{request_id}",
    response_model=FriendRequestResponse | None,
    summary="同意（accept=true）或拒绝好友申请",
)
async def respond_request(
    request_id: int,
    payload: FriendRequestAction,
    user: CurrentUser,
    session: SessionDep,
    hub: HubDep,
) -> FriendRequestResponse | None:
    result = await friend_service.respond_request(
        session, user_id=user.id, request_id=request_id, accept=payload.accept
    )
    if result is None:
        if not payload.accept:
            return None
        raise NotFoundError("申请不存在或已处理", code="request_not_found")
    other = await accounts.get_user(session, result.friend_id)
    if other is None:  # pragma: no cover - 申请双方必然存在
        raise NotFoundError("用户不存在", code="user_not_found")
    return _request_response(result, other, viewer_id=user.id, hub=hub)


@router.delete(
    "/requests/{request_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="撤回自己发出的好友申请",
)
async def cancel_request(
    request_id: int, user: CurrentUser, session: SessionDep
) -> Response:
    if not await friend_service.cancel_request(session, user_id=user.id, request_id=request_id):
        raise NotFoundError("申请不存在或已处理", code="request_not_found")
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.delete(
    "/{username}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="删除好友",
)
async def remove_friend(username: str, user: CurrentUser, session: SessionDep) -> Response:
    target = await accounts.get_user_by_username(session, username)
    if target is None:
        raise NotFoundError("用户不存在", code="user_not_found")
    if not await friend_service.remove_friend(session, user_id=user.id, friend_id=target.id):
        raise NotFoundError("你们还不是好友", code="not_friends")
    return Response(status_code=status.HTTP_204_NO_CONTENT)
