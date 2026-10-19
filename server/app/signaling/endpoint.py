"""信令 WebSocket 端点。

鉴权：客户端以 ``ws://host/ws?token=<JWT>`` 建连（也支持 ``Authorization: Bearer`` 头）。
鉴权失败时先完成握手再以 4401 关闭，让客户端能读到关闭码并给出明确提示。
"""

from __future__ import annotations

import logging

import anyio
from fastapi import WebSocket, WebSocketDisconnect
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.api.deps import resolve_token_user
from app.core.config import Settings
from app.core.errors import UnauthorizedError
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


async def signaling_endpoint(websocket: WebSocket) -> None:
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
