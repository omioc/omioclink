"""ORM → 响应模型的转换。"""

from app.db.models import Room, User
from app.schemas import RoomResponse, UserProfile
from app.signaling.hub import SignalingHub

__all__ = ["room_response", "user_profile"]


def user_profile(user: User, *, online: bool = False) -> UserProfile:
    return UserProfile(
        id=user.id,
        username=user.username,
        display_name=user.display_name,
        avatar=user.avatar,
        created_at=user.created_at,
        online=online,
    )


def room_response(
    room: Room,
    *,
    hub: SignalingHub,
    owner_name: str | None = None,
    joined: bool = False,
) -> RoomResponse:
    member_count = hub.state.live_member_count(room.id)
    return RoomResponse(
        room_id=room.id,
        name=room.name,
        owner_id=room.owner_id,
        owner_name=owner_name,
        capacity=room.capacity,
        member_count=member_count,
        has_password=room.has_password,
        is_public=room.is_public,
        created_at=room.created_at,
        online=member_count > 0,
        joined=joined,
    )
