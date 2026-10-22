"""登录记录：谁在什么时候、从哪个 IP 登录过（成功与失败都记）。

用途是**安全审计**：判断「有人在扫号」还是「自己忘了密码」，以及给限流提供事后依据。
只存用户名（客户端填的原样值）、来源 IP、User-Agent 与成败——不存密码、
不存会话内容，与「服务器不落任何媒体/聊天」的边界一致。

保留 30 天：登录是低频操作，每次插入顺手删过期记录，代价可以忽略
（``created_at`` 上有索引）。不做定时任务，省掉一个需要运维盯着的后台循环。
"""

from __future__ import annotations

from datetime import timedelta

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.models import LoginRecord, utcnow

__all__ = [
    "LOGIN_SOURCE_ADMIN",
    "LOGIN_SOURCE_CLIENT",
    "list_logins",
    "record_login",
    "retention",
]

#: 客户端账号登录
LOGIN_SOURCE_CLIENT = "client"

#: 管理台密码登录
LOGIN_SOURCE_ADMIN = "admin"

#: 记录保留时长
retention = timedelta(days=30)

#: UA 只留前 200 字符：够认出客户端版本，又不至于被长串塞满表
_USER_AGENT_LIMIT = 200


async def record_login(
    session: AsyncSession,
    *,
    source: str,
    username: str,
    ip: str,
    user_agent: str = "",
    success: bool,
) -> LoginRecord:
    """落一条登录记录，并顺手清掉过期记录。

    调用方**必须自己 commit**（见 ``app.api.auth.login``）：失败登录随后要抛 401，
    而请求结束后依赖里的 session 会回滚，不先落盘就白记了。
    """
    record = LoginRecord(
        source=source,
        username=username[:64],
        ip=ip[:64],
        user_agent=(user_agent or "")[:_USER_AGENT_LIMIT],
        success=success,
    )
    session.add(record)
    await session.execute(
        delete(LoginRecord).where(LoginRecord.created_at < utcnow() - retention)
    )
    await session.flush()
    return record


async def list_logins(
    session: AsyncSession, *, limit: int = 50, offset: int = 0, only_failed: bool = False
) -> list[LoginRecord]:
    """按时间倒序取登录记录（管理台用）。"""
    statement = select(LoginRecord).order_by(LoginRecord.id.desc())
    if only_failed:
        statement = statement.where(LoginRecord.success.is_(False))
    statement = statement.limit(limit).offset(offset)
    result = await session.execute(statement)
    return list(result.scalars().all())
