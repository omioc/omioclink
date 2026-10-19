"""REST 路由聚合。"""

from fastapi import APIRouter

from app.api import auth, avatars, friends, meta, music, rooms

api_router = APIRouter()
api_router.include_router(meta.router)
api_router.include_router(auth.router)
api_router.include_router(avatars.router)
api_router.include_router(rooms.router)
api_router.include_router(friends.router)
api_router.include_router(music.router)

__all__ = ["api_router"]
