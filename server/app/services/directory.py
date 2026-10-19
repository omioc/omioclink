"""信令层访问持久层的适配器。

信令连接是长连接，而 HTTP 请求各自带会话；这里用独立的短会话隔离两边。
"""

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.services import rooms as room_service
from app.signaling.state import RoomRecord

__all__ = ["SqlRoomDirectory"]


class SqlRoomDirectory:
    """``app.signaling.hub.RoomDirectory`` 端口的 SQLAlchemy 实现。"""

    def __init__(self, session_factory: async_sessionmaker[AsyncSession]) -> None:
        self._session_factory = session_factory

    async def load(self, room_id: str) -> RoomRecord | None:
        async with self._session_factory() as session:
            room = await room_service.get_room(session, room_id)
            return None if room is None else room_service.to_record(room)

    async def record_membership(self, room_id: str, user_id: int) -> None:
        async with self._session_factory() as session:
            await room_service.touch_membership(session, room_id, user_id)
            await session.commit()
