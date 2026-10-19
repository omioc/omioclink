"""账号服务。"""

from collections.abc import Sequence

from sqlalchemy import delete, func, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.security import hash_password, verify_password
from app.db.models import User

__all__ = [
    "authenticate",
    "change_password",
    "count_users",
    "create_user",
    "delete_user",
    "get_user",
    "get_user_by_username",
    "list_users",
    "set_user_disabled",
    "update_profile",
]


async def list_users(
    session: AsyncSession,
    *,
    query: str | None = None,
    limit: int = 100,
    offset: int = 0,
) -> Sequence[User]:
    """管理端用：列出账号，可按用户名/昵称模糊过滤。"""
    statement = select(User)
    if query:
        pattern = f"%{query.strip()}%"
        statement = statement.where(
            or_(User.username.ilike(pattern), User.display_name.ilike(pattern))
        )
    statement = statement.order_by(User.id).limit(limit).offset(offset)
    result = await session.execute(statement)
    return result.scalars().all()


async def count_users(session: AsyncSession, *, query: str | None = None) -> int:
    statement = select(func.count(User.id))
    if query:
        pattern = f"%{query.strip()}%"
        statement = statement.where(
            or_(User.username.ilike(pattern), User.display_name.ilike(pattern))
        )
    result = await session.execute(statement)
    return int(result.scalar_one())


async def get_user(session: AsyncSession, user_id: int) -> User | None:
    return await session.get(User, user_id)


async def get_user_by_username(session: AsyncSession, username: str) -> User | None:
    result = await session.execute(select(User).where(User.username == username))
    return result.scalar_one_or_none()


async def create_user(
    session: AsyncSession,
    *,
    username: str,
    password: str,
    display_name: str | None = None,
    avatar: str | None = None,
) -> User:
    user = User(
        username=username,
        display_name=display_name or username,
        password_hash=hash_password(password),
        avatar=avatar,
    )
    session.add(user)
    await session.flush()
    return user


async def authenticate(session: AsyncSession, username: str, password: str) -> User | None:
    user = await get_user_by_username(session, username)
    if user is None:
        # 仍然执行一次哈希校验，避免用响应时间区分「用户不存在」与「密码错误」
        verify_password(password, "$2b$12$" + "x" * 53)
        return None
    if not verify_password(password, user.password_hash):
        return None
    return user


async def change_password(session: AsyncSession, user: User, password: str) -> User:
    """改口令。

    口令一变，「口令指纹」随之变化，此前签发的所有令牌立即失效
    （见 ``app.core.security.password_fingerprint`` 与 ``app.api.deps``）。
    """
    user.password_hash = hash_password(password)
    await session.flush()
    return user


async def set_user_disabled(session: AsyncSession, user: User, *, disabled: bool) -> User:
    """启用 / 禁用账号。禁用后令牌立即失效（校验侧会拒绝），在线会话由调用方踢下线。"""
    user.disabled = disabled
    await session.flush()
    return user


async def delete_user(session: AsyncSession, user: User) -> None:
    """删除账号。

    名下的房间、进房历史、好友关系都靠外键 ON DELETE CASCADE 一并清理
    （SQLite 需要在连接上打开 PRAGMA foreign_keys，见 ``Database``）。
    """
    await session.execute(delete(User).where(User.id == user.id))


async def update_profile(
    session: AsyncSession,
    user: User,
    *,
    display_name: str | None = None,
) -> User:
    """改昵称。头像不走这里——它由 ``AvatarStore`` 落文件、由接口写版本号。"""
    if display_name is not None:
        user.display_name = display_name
    await session.flush()
    return user
