"""管理台账号：设置密码、校验密码。

服务器只有一个管理员，所以固定只存一行（``id = 1``），不需要用户表那套
「多账号 / 禁用 / 好友关系」语义。密码只存 bcrypt 哈希，明文既不落库也不进日志。

放在独立表而不是往 ``users`` 加 ``is_admin`` 列：管理员不该出现在客户端的
账号列表里，旧库也就不用再加列（``create_all`` 会直接把新表建出来）。
"""

from typing import Final

from sqlalchemy.ext.asyncio import AsyncSession

from app.core.security import hash_password, verify_password
from app.db.models import AdminAccount

__all__ = [
    "ADMIN_ID",
    "ADMIN_NAME",
    "authenticate",
    "get_admin",
    "has_admin",
    "set_password",
]

#: 单行表里固定的主键
ADMIN_ID: Final = 1

#: 管理台展示用的管理员名（不给改：只有密码是凭证）
ADMIN_NAME: Final = "admin"


async def get_admin(session: AsyncSession) -> AdminAccount | None:
    return await session.get(AdminAccount, ADMIN_ID)


async def has_admin(session: AsyncSession) -> bool:
    """是否已经设置过管理员密码（决定首次访问弹「设置密码」还是「登录」）。"""
    return await get_admin(session) is not None


async def set_password(session: AsyncSession, password: str) -> AdminAccount:
    """设置或重置管理员密码（首次调用即创建这一行）。"""
    admin = await get_admin(session)
    if admin is None:
        admin = AdminAccount(id=ADMIN_ID, password_hash=hash_password(password))
        session.add(admin)
    else:
        admin.password_hash = hash_password(password)
    await session.flush()
    return admin


async def authenticate(session: AsyncSession, password: str) -> AdminAccount | None:
    admin = await get_admin(session)
    if admin is None:
        # 还没有管理员：仍然算一次哈希，避免用响应时间区分「没设密码」与「密码错误」
        verify_password(password, "$2b$12$" + "x" * 53)
        return None
    if not verify_password(password, admin.password_hash):
        return None
    return admin
