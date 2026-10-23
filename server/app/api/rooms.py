"""房间接口。

REST 负责「房间元数据 + 房间列表」；进房后的实时信令与成员状态走 WebSocket
（``join_room`` / ``room_state`` / ...），两者共享同一份内存权威状态。
"""

from datetime import UTC, datetime
from typing import Literal

from fastapi import APIRouter, Query, Response, status

from app.api.deps import CurrentUser, HubDep, OptionalUser, SessionDep, SettingsDep
from app.api.serializers import room_response
from app.core.errors import ForbiddenError, NotFoundError, UnauthorizedError
from app.core.i18n import t
from app.db.models import Room, User
from app.schemas import (
    MemberListResponse,
    RoomCreateRequest,
    RoomListResponse,
    RoomResponse,
    RoomUpdateRequest,
)
from app.services import rooms as room_service
from app.signaling.hub import SignalingHub

router = APIRouter(prefix="/rooms", tags=["房间"])

_EPOCH = datetime(1970, 1, 1, tzinfo=UTC)


def _joined(hub: SignalingHub, user: User | None, room_id: str) -> bool:
    if user is None:
        return False
    return any(peer.room_id == room_id for peer in hub.state.peers_of_user(user.id))


def _to_response(
    room: Room, hub: SignalingHub, owner_name: str | None, user: User | None
) -> RoomResponse:
    return room_response(
        room,
        hub=hub,
        owner_name=owner_name,
        joined=_joined(hub, user, room.id),
    )


async def _get_room_or_404(session: SessionDep, room_id: str) -> Room:
    room = await room_service.get_room(session, room_id)
    if room is None:
        raise NotFoundError(t("room.not_found"), code="room_not_found")
    return room


@router.get("", response_model=RoomListResponse, summary="房间列表")
async def list_rooms(
    session: SessionDep,
    hub: HubDep,
    user: OptionalUser,
    scope: Literal["public", "mine"] = Query(
        default="public", description="public=公开房间，mine=我的房间"
    ),
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
) -> RoomListResponse:
    if scope == "mine":
        if user is None:
            raise UnauthorizedError
        rooms = await room_service.list_user_rooms(
            session, user_id=user.id, limit=limit, offset=offset
        )
    else:
        rooms = await room_service.list_public_rooms(session, limit=limit, offset=offset)

    names = await room_service.owner_names(session, rooms)
    items = [_to_response(room, hub, names.get(room.owner_id), user) for room in rooms]
    # 当前用户已在房间内 / 有人在线的排前面，其余按创建时间
    items.sort(
        key=lambda item: (item.joined, item.online, item.created_at or _EPOCH), reverse=True
    )
    return RoomListResponse(items=items, total=len(items))


@router.post(
    "",
    response_model=RoomResponse,
    status_code=status.HTTP_201_CREATED,
    summary="创建房间",
)
async def create_room(
    payload: RoomCreateRequest,
    user: CurrentUser,
    session: SessionDep,
    settings: SettingsDep,
    hub: HubDep,
) -> RoomResponse:
    capacity = payload.capacity or settings.default_room_capacity
    room = await room_service.create_room(
        session,
        owner=user,
        name=payload.name,
        capacity=capacity,
        password=payload.password,
        is_public=payload.is_public,
        settings=settings,
    )
    return _to_response(room, hub, user.display_name, user)


@router.get("/{room_id}", response_model=RoomResponse, summary="房间详情")
async def get_room(
    room_id: str, session: SessionDep, hub: HubDep, user: OptionalUser
) -> RoomResponse:
    room = await _get_room_or_404(session, room_id)
    names = await room_service.owner_names(session, [room])
    return _to_response(room, hub, names.get(room.owner_id), user)


@router.patch("/{room_id}", response_model=RoomResponse, summary="修改房间（房主）")
async def update_room(
    room_id: str,
    payload: RoomUpdateRequest,
    user: CurrentUser,
    session: SessionDep,
    settings: SettingsDep,
    hub: HubDep,
) -> RoomResponse:
    room = await _get_room_or_404(session, room_id)
    if room.owner_id != user.id:
        raise ForbiddenError(t("room.owner_only_update"))
    room = await room_service.update_room(
        session,
        room,
        name=payload.name,
        capacity=payload.capacity,
        is_public=payload.is_public,
        settings=settings,
    )
    if payload.capacity is not None:
        # 容量缩小后，把超出的成员请出房间
        existing = hub.state.get_room(room_id)
        if existing is not None:
            existing.capacity = room.capacity
        await hub.kick_room_members(room_id, reason="room_capacity_changed")
    return _to_response(room, hub, user.display_name, user)


@router.delete(
    "/{room_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="解散房间（房主）",
)
async def delete_room(
    room_id: str, user: CurrentUser, session: SessionDep, hub: HubDep
) -> Response:
    room = await _get_room_or_404(session, room_id)
    if room.owner_id != user.id:
        raise ForbiddenError(t("room.owner_only_delete"))
    await hub.close_room(room_id, reason="closed")
    await room_service.delete_room(session, room)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get(
    "/{room_id}/members",
    response_model=MemberListResponse,
    summary="房间在线成员（实时）",
)
async def room_members(room_id: str, session: SessionDep, hub: HubDep) -> MemberListResponse:
    await _get_room_or_404(session, room_id)
    live = hub.state.get_room(room_id)
    items = live.member_infos() if live is not None else []
    return MemberListResponse(items=items, total=len(items))


@router.post("/{room_id}/leave", summary="退出房间（REST 兜底）")
async def leave_room(
    room_id: str, user: CurrentUser, session: SessionDep, hub: HubDep
) -> dict[str, int]:
    await _get_room_or_404(session, room_id)
    return {"left": await hub.leave_room_for_user(user.id, room_id)}
