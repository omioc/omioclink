"""点歌台接口：只下发「音乐插件订阅地址」。

服务器在这里的职责只剩一件事：把部署者配置的若干条订阅 URL 交给登录用户。
**不执行、不代理、不缓存任何音乐元数据**——搜索、歌单、排行榜、播放地址解析
全部由客户端用 MusicFree 插件自己完成（插件从这些 URL 下载安装）。

需要登录（与房间等接口一致，避免服务器被当成公开的配置分发点）。
"""

from __future__ import annotations

from fastapi import APIRouter

from app.api.deps import CurrentUser, PluginSubscriptionStoreDep
from app.schemas import PluginSubscriptionResponse
from app.services.plugin_subscription import subscription_hash

router = APIRouter(prefix="/music", tags=["点歌台"])


@router.get(
    "/plugin-subscription",
    response_model=PluginSubscriptionResponse,
    summary="音乐插件订阅地址（客户端据此下载安装插件）",
)
async def plugin_subscription(
    store: PluginSubscriptionStoreDep, _user: CurrentUser
) -> PluginSubscriptionResponse:
    urls = await store.read()
    # 没配置时返回空列表 + 空列表哈希（200），客户端据此显示「服务器未提供插件」
    return PluginSubscriptionResponse(urls=urls, hash=subscription_hash(urls))
