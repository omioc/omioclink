"""应用入口。

服务器职责边界（架构性约束，不是配置项）：
    账号 / 好友 / 房间元数据 / 成员状态 + WebRTC 信令转发 + ICE(STUN) 配置下发
    + 点歌台的**音乐插件订阅地址**（只下发几条 URL，客户端自己下载安装插件）。
    这里没有媒体收发、没有 TURN、没有任何中继通道，也不解析任何音乐元数据。
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import anyio
from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import HTMLResponse, JSONResponse, Response
from starlette.exceptions import HTTPException as StarletteHTTPException

from app.api.admin import router as admin_router
from app.api.admin import serve_admin_logo, serve_admin_page
from app.api.router import api_router
from app.core.config import Settings, get_settings
from app.core.errors import ApiError
from app.db.base import Database
from app.services.avatars import AvatarStore
from app.services.directory import SqlRoomDirectory
from app.services.plugin_subscription import PluginSubscriptionStore
from app.services.server_secret import ServerSecretStore
from app.signaling.endpoint import signaling_endpoint
from app.signaling.hub import SignalingHub

logger = logging.getLogger(__name__)

__all__ = ["app", "create_app"]

DESCRIPTION = """
OmiocLink 信令服务器。

* REST：账号、好友、房间元数据、服务器信息
* 点歌台：音乐插件订阅地址下发（客户端自己下载安装插件），不代理任何音乐数据
* WebSocket（信令）：房间进入/离开、成员状态、`offer`/`answer`/`candidate` 转发、心跳
* Web 管理台：`/admin` 常开，首次打开时设置管理员密码，之后用密码登录
* **不包含任何媒体中继**：`mediaRelay` 恒为 false，服务器不存在 TURN/relay 组件
"""


def create_app(settings: Settings | None = None) -> FastAPI:
    """组装应用。"""
    resolved = settings or get_settings()
    # JWT 密钥允许留空：没配就用数据目录里持久化的那一份，第一次启动时自动生成并落盘
    resolved.jwt_secret = ServerSecretStore(resolved.data_dir).ensure_jwt_secret(
        resolved.jwt_secret
    )
    if resolved.legacy_admin_token is not None:
        logger.warning(
            "检测到已废弃的 OMIOCLINK_ADMIN_TOKEN：它只在新版管理台「还没设置管理员密码」时"
            "可用，设完密码即失效，建议从 .env 删掉"
        )
    database = Database(resolved.database_url)
    hub = SignalingHub(resolved, SqlRoomDirectory(database.session_factory))
    avatars = AvatarStore(resolved.data_dir)
    plugin_subscription = PluginSubscriptionStore(resolved.data_dir)

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        await database.create_all()
        heartbeat = asyncio.create_task(hub.heartbeat_loop(), name="signaling-heartbeat")
        # 点歌队列推进（1 秒粒度）：duration 可信时按时间切歌，不依赖客户端上报 EOS
        music_tick = asyncio.create_task(hub.music_tick_loop(), name="signaling-music")
        # OMIOCLINK_DEBUG_TASKS=1 时每 0.5 秒打印一次事件循环里所有任务的位置。
        # 排查「服务卡住不响应」时比看线程栈有效得多（协程栈 faulthandler 看不到）。
        debug_dump = (
            asyncio.create_task(_debug_dump_tasks(), name="debug-dump-tasks")
            if os.environ.get("OMIOCLINK_DEBUG_TASKS")
            else None
        )
        try:
            yield
        finally:
            # 停机收尾必须完整跑完，否则会留下半关闭的 aiosqlite 连接：
            # SQLAlchemy 的 terminate() 内部是 await_(asyncio.shield(graceful_close))，
            # 一旦被取消打断，那个连接的终止流程就永远停在 _terminate_graceful_close 上，
            # 事件循环里会残留卡死的任务（实测：接不到信号、循环空转、请求永不返回）。
            with anyio.CancelScope(shield=True):
                heartbeat.cancel()
                music_tick.cancel()
                if debug_dump is not None:
                    debug_dump.cancel()
                for task in (heartbeat, music_tick, debug_dump):
                    if task is None:
                        continue
                    with contextlib.suppress(asyncio.CancelledError):
                        await task
                await hub.shutdown()
                await database.dispose()

    app = FastAPI(
        title=resolved.app_name,
        version=resolved.version,
        description=DESCRIPTION,
        lifespan=lifespan,
        # /docs 与 /openapi.json 默认关闭：它们会把整个 API 面（含注册接口的存在）
        # 暴露给任何能访问端口的人。需要时用 OMIOCLINK_DOCS_ENABLED=true 打开。
        docs_url="/docs" if resolved.docs_enabled else None,
        openapi_url="/openapi.json" if resolved.docs_enabled else None,
        redoc_url=None,
    )

    app.state.settings = resolved
    app.state.database = database
    app.state.session_factory = database.session_factory
    app.state.hub = hub
    app.state.avatars = avatars
    app.state.plugin_subscription = plugin_subscription

    origins = list(resolved.cors_origins)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=origins,
        allow_credentials="*" not in origins,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    _install_error_handlers(app)
    app.include_router(api_router, prefix=resolved.api_prefix)
    app.add_api_websocket_route(resolved.websocket_path, signaling_endpoint)

    # 管理台常开：/admin 与 /api/v1/admin/* 一直都在，第一次打开时由页面引导设置管理员密码
    app.include_router(admin_router, prefix=resolved.api_prefix)
    app.add_api_route(
        "/admin",
        serve_admin_page,
        methods=["GET"],
        include_in_schema=False,
        response_class=HTMLResponse,
    )
    app.add_api_route(
        "/admin/logo.png",
        serve_admin_logo,
        methods=["GET"],
        include_in_schema=False,
        response_class=Response,
    )
    return app


async def _debug_dump_tasks() -> None:  # pragma: no cover - 临时排查用
    """每 0.5 秒打印事件循环里所有任务的位置（排查挂起用，靠环境变量开启）。"""
    while True:
        await asyncio.sleep(0.5)
        print("---- DUMP ----", flush=True)
        for task in asyncio.all_tasks():
            if task.done():
                continue
            frames = task.get_stack()[-10:]
            if not frames:
                print(f"  [{task.get_name()}] (no frames)", flush=True)
                continue
            chain = " <- ".join(
                f"{os.path.basename(frame.f_code.co_filename)}:{frame.f_lineno}:{frame.f_code.co_name}"
                for frame in reversed(frames)
            )
            print(f"  [{task.get_name()}] {chain}", flush=True)


def _install_error_handlers(app: FastAPI) -> None:
    @app.exception_handler(ApiError)
    async def _handle_api_error(_request: Request, exc: ApiError) -> JSONResponse:
        return JSONResponse(status_code=exc.status_code, content=exc.payload)

    @app.exception_handler(RequestValidationError)
    async def _handle_validation_error(
        _request: Request, exc: RequestValidationError
    ) -> JSONResponse:
        first = exc.errors()[0] if exc.errors() else {}
        location = ".".join(str(part) for part in first.get("loc", ()) if part != "body")
        message = first.get("msg", "参数校验失败")
        return JSONResponse(
            status_code=422,
            content={
                "code": "invalid_request",
                "message": f"{location}: {message}" if location else str(message),
                "errors": [
                    {"loc": [str(part) for part in err.get("loc", ())], "msg": err.get("msg", "")}
                    for err in exc.errors()
                ],
            },
        )

    @app.exception_handler(StarletteHTTPException)
    async def _handle_http_error(
        _request: Request, exc: StarletteHTTPException
    ) -> JSONResponse:
        return JSONResponse(
            status_code=exc.status_code,
            content={"code": f"http_{exc.status_code}", "message": str(exc.detail)},
        )

    @app.exception_handler(Exception)
    async def _handle_unexpected(_request: Request, exc: Exception) -> JSONResponse:
        logger.exception("未处理的异常", exc_info=exc)
        return JSONResponse(
            status_code=500,
            content={"code": "internal_error", "message": "服务器内部错误"},
        )


app = create_app()
