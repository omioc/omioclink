"""信令 WebSocket 端点。

鉴权：客户端以 ``ws://host/ws?token=<JWT>`` 建连（也支持 ``Authorization: Bearer`` 头）。
鉴权失败时先完成握手再以 4401 关闭，让客户端能读到关闭码并给出明确提示。

语言：客户端可再加一个 ``lang=zh|en|ja|ko`` 查询参数，这条连接下发给它的
``error.message``（``ws.*`` 文案）按它翻译，缺失或非法一律回落中文。为什么不复用
``Accept-Language`` 头：WebSocket 构造函数在浏览器里不允许自定义请求头，桌面端也统一
走同一个 URL —— 查询参数是两端都能可靠带上的位置。
"""

from __future__ import annotations

import logging

import anyio
from fastapi import WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import resolve_token_user
from app.core.config import Settings
from app.core.errors import UnauthorizedError
from app.core.i18n import Locale, parse_accept_language, reset_current_locale, set_current_locale
from app.db.models import User
from app.signaling.hub import SignalingHub
from app.signaling.state import CloseCode, Peer

logger = logging.getLogger(__name__)

__all__ = ["signaling_endpoint"]


def _extract_token(websocket: WebSocket) -> str | None:
    token = websocket.query_params.get("token")
    if token:
        return token
    header = websocket.headers.get("authorization") or ""
    if header.lower().startswith("bearer "):
        return header[len("bearer ") :].strip()
    return None


async def _authenticate(
    websocket: WebSocket,
    settings: Settings,
    session_factory: async_sessionmaker[AsyncSession],
) -> User | None:
    """校验令牌并取出用户。

    刻意复用 REST 侧同一套 ``resolve_token_user``：令牌解码、用户存在性、
    账号是否被禁用这些判定只存在一处，避免 WS 这条路上漏掉后续新增的校验。
    """
    token = _extract_token(websocket)
    if not token:
        return None
    async with session_factory() as session:
        try:
            return await resolve_token_user(session, settings, token)
        except UnauthorizedError:
            return None


async def _safe_close(websocket: WebSocket, code: int, reason: str) -> None:
    try:
        await websocket.close(code=code, reason=reason)
    except RuntimeError:  # pragma: no cover - 连接已断开
        logger.debug("关闭 WebSocket 失败 reason=%s", reason, exc_info=True)


def _connection_locale(websocket: WebSocket) -> Locale:
    """这条连接的语言：取 ``?lang=``，缺失或非法都回落中文。

    复用 ``parse_accept_language`` 而不是自己比对四个字符串：它已经处理了大小写、
    ``zh-CN`` 这类带地区子标签的写法和 q 值；另写一套判定，两处迟早会漂开。
    """
    return parse_accept_language(websocket.query_params.get("lang"))


async def signaling_endpoint(websocket: WebSocket) -> None:
    """入口：先按 ``?lang=`` 固定这条连接的语言，再跑真正的工作。

    拆出 ``_serve_connection`` 是为了把 locale 的压入 / 还原收在一处：连接的所有出口
    （鉴权失败的提前 return、正常断开、异常）都要还原上下文变量，否则同一条事件循环里
    后续的连接会沿用上一条连接的语言。
    """
    token = set_current_locale(_connection_locale(websocket))
    try:
        await _serve_connection(websocket)
    finally:
        reset_current_locale(token)


async def _serve_connection(websocket: WebSocket) -> None:
    settings: Settings = websocket.app.state.settings
    hub: SignalingHub = websocket.app.state.hub
    session_factory: async_sessionmaker[AsyncSession] = websocket.app.state.session_factory

    await websocket.accept()

    user = await _authenticate(websocket, settings, session_factory)
    if user is None:
        await _safe_close(websocket, CloseCode.UNAUTHORIZED, "unauthorized")
        return

    peer = await hub.register(
        websocket,
        user_id=user.id,
        username=user.username,
        display_name=user.display_name,
        avatar=user.avatar,
    )
    try:
        await _receive_loop(websocket, hub, peer)
    except WebSocketDisconnect:
        pass
    except Exception:  # pragma: no cover - 兜底，避免连接泄漏
        logger.exception("信令连接异常 peer_id=%s", peer.peer_id)
        await _safe_close(websocket, CloseCode.INTERNAL_ERROR, "internal_error")
    finally:
        # 掉线收尾必须完整执行（回收房间状态 + 向同房间成员广播 member_left）。
        # 服务端停机 / 测试框架关闭连接都会 cancel 本任务，若不屏蔽取消，
        # 收尾会在第一个 await 处被打断，导致房间里其他人永远等不到 member_left。
        with anyio.CancelScope(shield=True):
            await hub.unregister(peer.peer_id)


async def _receive_loop(websocket: WebSocket, hub: SignalingHub, peer: Peer) -> None:
    while hub.state.get_peer(peer.peer_id) is not None:
        try:
            message = await websocket.receive()
        except RuntimeError:
            # 本端已经调用过 close（例如被新会话顶下线）
            break
        if message["type"] == "websocket.disconnect":
            break
        text = message.get("text")
        if text is None:
            # 协议只使用文本帧；二进制帧直接忽略
            continue
        await hub.handle_text(peer, text)
