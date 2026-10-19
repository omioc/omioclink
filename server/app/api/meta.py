"""服务器元信息与健康检查。

``/server/info`` 是客户端「服务器配置页」的数据源；其中 ``mediaRelay`` 恒为 false——
服务器只做信令/状态/连接发现，不部署任何媒体中继组件。
"""

from typing import Any

from fastapi import APIRouter

from app.api.deps import HubDep, SettingsDep
from app.schemas import ServerInfoResponse

router = APIRouter(tags=["服务器"])


@router.get("/health", summary="健康检查")
async def health(hub: HubDep) -> dict[str, Any]:
    return {"status": "ok", **hub.stats()}


@router.get("/server/info", response_model=ServerInfoResponse, summary="服务器能力与 ICE 配置")
async def server_info(settings: SettingsDep) -> ServerInfoResponse:
    return ServerInfoResponse(
        name=settings.server_name,
        version=settings.version,
        protocol_version=settings.protocol_version,
        room_capacity=settings.default_room_capacity,
        max_room_capacity=settings.room_capacity_ceiling,
        ice_servers=list(settings.ice_servers),
        heartbeat_interval=settings.heartbeat_interval_seconds,
        websocket_path=settings.websocket_path,
        api_prefix=settings.api_prefix,
        allow_registration=settings.allow_registration,
        music_enabled=settings.music_enabled,
    )
