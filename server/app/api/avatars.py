"""头像读取接口。

上传/移除在 ``/auth/avatar``（属于账号资料），这里只负责按版本号把图片发出去。
"""

from fastapi import APIRouter, Query, Response

from app.api.deps import AvatarStoreDep, CurrentUser
from app.core.errors import NotFoundError
from app.core.i18n import t

router = APIRouter(prefix="/avatars", tags=["头像"])


@router.get(
    "/{user_id}",
    summary="按版本号读取用户头像",
    response_class=Response,
    responses={200: {"content": {"image/png": {}, "image/jpeg": {}}}},
)
async def get_avatar(
    user_id: int,
    store: AvatarStoreDep,
    _: CurrentUser,
    v: str = Query(description="头像版本号（来自账号资料里的 avatar 字段）"),
) -> Response:
    """返回头像图片字节。

    * 需要登录：头像不对外开放，避免被当成图床或被人遍历用户 id 抓取；
    * 版本号是内容哈希，所以 URL 变了内容才会变，可以放心长缓存。
    """
    image = store.load(user_id, v)
    if image is None:
        raise NotFoundError(t("avatar.not_found"), code="avatar_not_found")
    return Response(
        content=image.data,
        media_type=image.content_type,
        headers={
            # private：带头鉴权的资源不能被共享缓存留存
            "Cache-Control": "private, max-age=31536000, immutable",
            # 类型已按文件头确认过，禁止浏览器再按内容嗅探（防 MIME 混淆）
            "X-Content-Type-Options": "nosniff",
        },
    )
