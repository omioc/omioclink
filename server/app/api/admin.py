"""Web 管理台与 ``/api/v1/admin/*`` 接口。

**管理台永远存在**：不再靠环境变量开关（以前没配 ``OMIOCLINK_ADMIN_TOKEN`` 时
连路由都不注册，配了还得让用户去 .env 里翻那个令牌）。第一次打开 ``/admin``
时页面要求设置管理员密码，之后用这个密码登录——哈希存在库里
（``admin_account`` 表，见 ``app.services.admin_account``）。

两种凭证都走 ``Authorization: Bearer``：

* 管理台登录态：``app.core.security.create_admin_token`` 签的 JWT，``scope=admin``，
  有效期 ``OMIOCLINK_ADMIN_SESSION_TTL_SECONDS``（默认 12 小时）；
* 旧版 ``X-Admin-Token``：``OMIOCLINK_ADMIN_TOKEN`` 已废弃，只在**还没设置管理员
  密码**时被接受，设置完立即失效——老部署照原样启动也能平滑迁移过来。
"""

from __future__ import annotations

import hmac
import logging
from pathlib import Path
from typing import Annotated, Final
from urllib.parse import urlsplit

from fastapi import APIRouter, Depends, Header, Query, Request, Response, status
from fastapi.responses import HTMLResponse
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.api.deps import (
    CredentialsDep,
    HubDep,
    LoginLimitsDep,
    PluginSubscriptionStoreDep,
    SessionDep,
    SettingsDep,
)
from app.api.serializers import room_response
from app.core.config import Settings
from app.core.errors import (
    ConflictError,
    ForbiddenError,
    NotFoundError,
    TooManyRequestsError,
    UnauthorizedError,
    ValidationError,
)
from app.core.ratelimit import client_ip
from app.core.security import (
    ADMIN_SCOPE,
    BCRYPT_MAX_BYTES,
    create_admin_token,
    decode_access_token,
    password_fingerprint,
    verify_password,
)
from app.db.models import AdminAccount, User
from app.schemas import (
    AdminActionResult,
    AdminKickRequest,
    AdminLoginListResponse,
    AdminLoginRecordResponse,
    AdminLoginResponse,
    AdminOverview,
    AdminPasswordRequest,
    AdminPluginSubscription,
    AdminPluginSubscriptionUpdate,
    AdminRegistrationToggle,
    AdminSessionStatus,
    AdminUserListResponse,
    AdminUserResponse,
    AdminUserUpdate,
    MemberListResponse,
    PasswordChangeRequest,
    RegisterRequest,
    RoomListResponse,
)
from app.services import accounts, admin_account, logins
from app.services import rooms as room_service
from app.signaling.hub import SignalingHub

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/admin", tags=["管理"])

#: 管理页静态文件（随 app 一起打进镜像）
ADMIN_PAGE_PATH = Path(__file__).resolve().parent.parent / "web" / "admin.html"

#: 管理页的品牌图标（页面左上角 + 浏览器页签），由仓库根的 OmiocLink.png 生成
ADMIN_LOGO_PATH = Path(__file__).resolve().parent.parent / "web" / "logo.png"


async def _verify_admin_token(
    session: AsyncSession, settings: Settings, token: str | None
) -> bool:
    """校验管理台登录态令牌：签名 → scope → 口令指纹（改密码即全部失效）。"""
    if not token:
        return False
    payload = decode_access_token(
        token, secret=settings.jwt_secret, algorithm=settings.jwt_algorithm
    )
    if payload is None or payload.get("scope") != ADMIN_SCOPE:
        return False
    admin = await admin_account.get_admin(session)
    if admin is None:
        return False
    expected = password_fingerprint(
        secret=settings.jwt_secret, password_hash=admin.password_hash
    )
    return payload.get("pwf") == expected


async def require_admin(
    session: SessionDep,
    settings: SettingsDep,
    credentials: CredentialsDep = None,
    x_admin_token: Annotated[str | None, Header()] = None,
) -> None:
    token = credentials.credentials if credentials is not None else None
    if await _verify_admin_token(session, settings, token):
        return

    legacy = (x_admin_token or "").strip()
    if not legacy:
        # 没带令牌或令牌过期：前端据此弹「密码登录」框
        raise UnauthorizedError("请先登录管理台", code="admin_session_invalid")

    expected = settings.legacy_admin_token
    # 按字节比：头里的值可能是任意字节，非 ASCII 的 str 直接喂给 compare_digest 会抛 TypeError
    matched = expected is not None and hmac.compare_digest(
        legacy.encode("utf-8", "surrogateescape"), expected.encode("utf-8")
    )
    if not matched:
        raise UnauthorizedError("管理令牌不正确", code="bad_admin_token")
    if await admin_account.has_admin(session):
        # 迁移已经完成：旧钥匙立刻作废（只作过渡用，不长期养两套凭证）
        raise UnauthorizedError(
            "旧的管理令牌已停用，请用管理员密码登录", code="admin_token_retired"
        )


AdminDep = Annotated[None, Depends(require_admin)]

#: 浏览器自己填的 Sec-Fetch-Site：出现这两个值说明请求来自别的网站
_BROWSER_CROSS_SITES: Final = frozenset({"cross-site", "same-site"})


async def require_same_origin_browser(request: Request) -> None:
    """给「设置密码 / 登录」这两个免鉴权接口挡一道 CSRF。

    它们不需要任何凭证，而共享的 CORS 允许任意来源（客户端是桌面应用，本来就不走
    浏览器同源策略）—— 不加这道拦截，任何网站都能借访客的浏览器把管理员密码设掉。

    * ``Sec-Fetch-Site`` 由浏览器填写、JS 改不了：跨站直接拒绝；没有这个头
      （老浏览器 / curl / 脚本）就继续往下判断；
    * 再退回对比 ``Origin`` 与 ``Host``：老浏览器带了 Origin 却不是同源，同样拒绝。
      反代把 Host 改写成上游地址时，现代浏览器仍会带 ``Sec-Fetch-Site``，不受影响。
    """
    site = request.headers.get("sec-fetch-site")
    if site is not None:
        if site.strip().lower() in _BROWSER_CROSS_SITES:
            raise ForbiddenError(
                "不允许从其他网站调用管理接口，请打开 /admin 操作",
                code="cross_origin_blocked",
            )
        return
    origin = request.headers.get("origin")
    if not origin:
        return  # 没有 Origin：脚本 / curl，不受浏览器同源策略约束
    host = (request.headers.get("host") or "").strip().lower()
    if not host or urlsplit(origin).netloc.lower() != host:
        raise ForbiddenError(
            "不允许从其他网站调用管理接口，请打开 /admin 操作", code="cross_origin_blocked"
        )


SameOriginDep = Annotated[None, Depends(require_same_origin_browser)]

def _issue_admin_token(admin: AdminAccount, settings: Settings) -> AdminLoginResponse:
    secret = settings.jwt_secret
    token = create_admin_token(
        secret=secret,
        algorithm=settings.jwt_algorithm,
        ttl_seconds=settings.admin_session_ttl_seconds,
        password_fingerprint=password_fingerprint(
            secret=secret, password_hash=admin.password_hash
        ),
    )
    return AdminLoginResponse(
        access_token=token,
        expires_in=settings.admin_session_ttl_seconds,
        username=admin_account.ADMIN_NAME,
    )


def _check_password_strength(password: str, settings: Settings) -> None:
    minimum = settings.password_min_length
    if len(password) < minimum:
        raise ValidationError(f"密码至少 {minimum} 位", code="weak_password")
    # bcrypt 只处理前 72 字节：宁可明确报错，也不静默截断（见 BCRYPT_MAX_BYTES）
    if len(password.encode("utf-8")) > BCRYPT_MAX_BYTES:
        raise ValidationError("密码过长（最多 72 字节）", code="password_too_long")


@router.get(
    "/session",
    response_model=AdminSessionStatus,
    summary="管理台状态（要不要设置密码 / 要不要登录）",
)
async def session_status(
    session: SessionDep, settings: SettingsDep, credentials: CredentialsDep = None
) -> AdminSessionStatus:
    initialized = await admin_account.has_admin(session)
    token = credentials.credentials if credentials is not None else None
    authenticated = initialized and await _verify_admin_token(session, settings, token)
    return AdminSessionStatus(
        initialized=initialized,
        authenticated=authenticated,
        legacy_token_configured=settings.legacy_admin_token is not None,
        password_min_length=settings.password_min_length,
        username=admin_account.ADMIN_NAME if authenticated else None,
    )


@router.post(
    "/setup",
    response_model=AdminLoginResponse,
    status_code=status.HTTP_201_CREATED,
    summary="首次设置管理员密码（只在还没设置时可用）",
)
async def setup_admin(
    payload: AdminPasswordRequest,
    session: SessionDep,
    settings: SettingsDep,
    _: SameOriginDep,
) -> AdminLoginResponse:
    if await admin_account.has_admin(session):
        raise ConflictError("管理员密码已经设置过了，请直接登录", code="admin_already_initialized")
    _check_password_strength(payload.password, settings)
    try:
        admin = await admin_account.set_password(session, payload.password)
    except IntegrityError as exc:
        # 两个人同时点「设置」：主键冲突的那一方落到这里，结果是一致的
        raise ConflictError(
            "管理员密码已经设置过了，请直接登录", code="admin_already_initialized"
        ) from exc
    logger.warning("管理台管理员密码已设置（哈希存进 admin_account 表）")
    if settings.legacy_admin_token is not None:
        logger.warning("OMIOCLINK_ADMIN_TOKEN 从现在起不再被接受，建议从 .env 里删掉")
    return _issue_admin_token(admin, settings)


@router.post("/login", response_model=AdminLoginResponse, summary="管理员登录")
async def login(
    payload: AdminPasswordRequest,
    request: Request,
    session: SessionDep,
    settings: SettingsDep,
    limits: LoginLimitsDep,
    _: SameOriginDep,
) -> AdminLoginResponse:
    if not await admin_account.has_admin(session):
        raise ConflictError("还没有设置管理员密码，请先设置", code="admin_not_initialized")
    ip = client_ip(request)
    # 管理台只有一个账号，没有「换个用户名再试」的空间，所以按来源 IP 锁定：
    # 连续错 5 次 → 5 分钟内连正确的密码也不放行（否则猜对那一次等于没锁）。
    wait = limits.admin.locked_for(ip)
    if wait > 0:
        raise TooManyRequestsError(
            f"密码错误次数过多，请 {round(wait)} 秒后再试",
            code="admin_locked",
            retry_after=wait,
        )
    admin = await admin_account.authenticate(session, payload.password)
    if admin is None:
        wait = limits.admin.record_failure(ip)
        await logins.record_login(
            session,
            source=logins.LOGIN_SOURCE_ADMIN,
            username=admin_account.ADMIN_NAME,
            ip=ip,
            user_agent=request.headers.get("user-agent", ""),
            success=False,
        )
        # 先落盘再抛：401 会让会话依赖回滚，审计记录得自己 commit
        await session.commit()
        if wait > 0:
            raise TooManyRequestsError(
                f"密码错误次数过多，请 {round(wait)} 秒后再试",
                code="admin_locked",
                retry_after=wait,
            )
        raise UnauthorizedError("管理员密码不正确", code="bad_admin_password")
    limits.admin.clear(ip)
    await logins.record_login(
        session,
        source=logins.LOGIN_SOURCE_ADMIN,
        username=admin_account.ADMIN_NAME,
        ip=ip,
        user_agent=request.headers.get("user-agent", ""),
        success=True,
    )
    return _issue_admin_token(admin, settings)


@router.post(
    "/password",
    response_model=AdminLoginResponse,
    summary="修改管理员密码（其他设备的登录态立即失效）",
)
async def change_password(
    payload: PasswordChangeRequest,
    session: SessionDep,
    settings: SettingsDep,
    _: AdminDep,
) -> AdminLoginResponse:
    admin = await admin_account.get_admin(session)
    if admin is None:  # pragma: no cover - require_admin 已经确认管理员存在
        raise UnauthorizedError("请先设置管理员密码", code="admin_not_initialized")
    # 用 403 而不是 401：401 会被前端当作「登录态失效」直接弹回登录框，
    # 而这里只是表单里的当前密码填错了
    if not verify_password(payload.current_password, admin.password_hash):
        raise ForbiddenError("当前密码不正确", code="bad_current_password")
    if payload.new_password == payload.current_password:
        raise ValidationError("新密码不能与当前密码相同", code="password_unchanged")
    _check_password_strength(payload.new_password, settings)
    admin = await admin_account.set_password(session, payload.new_password)
    logger.warning("管理台管理员密码已修改：此前签发的管理台令牌全部失效")
    # 口令指纹变了 → 别的设备立刻掉线；这台设备换一张新令牌，不用重新登录
    return _issue_admin_token(admin, settings)


async def _build_overview(
    session: SessionDep, hub: SignalingHub, settings: Settings
) -> AdminOverview:
    return AdminOverview(
        server_name=settings.server_name,
        version=settings.version,
        user_count=await accounts.count_users(session),
        room_count=await room_service.count_rooms(session),
        public_room_count=await room_service.count_rooms(session, public_only=True),
        live_peer_count=hub.state.live_peer_count,
        live_room_count=hub.state.live_room_count,
        allow_registration=settings.allow_registration,
        docs_enabled=settings.docs_enabled,
    )


@router.get("/overview", response_model=AdminOverview, summary="服务器概览")
async def overview(
    session: SessionDep, hub: HubDep, settings: SettingsDep, _: AdminDep
) -> AdminOverview:
    return await _build_overview(session, hub, settings)


@router.post(
    "/registration",
    response_model=AdminOverview,
    summary="临时开/关用户自注册（重启后回到 .env 配置）",
)
async def toggle_registration(
    payload: AdminRegistrationToggle,
    session: SessionDep,
    hub: HubDep,
    settings: SettingsDep,
    _: AdminDep,
) -> AdminOverview:
    # Settings 非 frozen，运行时改对 get_settings_dep（读 app.state.settings）立即生效
    settings.allow_registration = payload.allow
    return await _build_overview(session, hub, settings)


@router.get("/rooms", response_model=RoomListResponse, summary="全部房间（含私有）")
async def list_rooms(
    session: SessionDep,
    hub: HubDep,
    _: AdminDep,
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
) -> RoomListResponse:
    rooms = await room_service.list_all_rooms(session, limit=limit, offset=offset)
    names = await room_service.owner_names(session, rooms)
    items = [
        room_response(room, hub=hub, owner_name=names.get(room.owner_id), joined=False)
        for room in rooms
    ]
    # 有人的排前面（稳定排序，保留 SQL 的更新时间次序）
    items.sort(key=lambda item: item.member_count, reverse=True)
    return RoomListResponse(items=items, total=await room_service.count_rooms(session))


@router.get(
    "/rooms/{room_id}/members",
    response_model=MemberListResponse,
    summary="房间在线成员（实时）",
)
async def room_members(room_id: str, hub: HubDep, _: AdminDep) -> MemberListResponse:
    live = hub.state.get_room(room_id)
    items = live.member_infos() if live is not None else []
    return MemberListResponse(items=items, total=len(items))


@router.post(
    "/rooms/{room_id}/kick",
    response_model=AdminActionResult,
    summary="把某条会话踢出房间",
)
async def kick_member(
    room_id: str, payload: AdminKickRequest, hub: HubDep, _: AdminDep
) -> AdminActionResult:
    peer = hub.state.get_peer(payload.peer_id)
    if peer is None:
        raise NotFoundError("该会话已离线", code="peer_not_found")
    if peer.room_id != room_id:
        raise ValidationError("该会话不在指定房间内")
    await hub.kick_peer(payload.peer_id, reason="kicked_by_admin")
    return AdminActionResult(detail=f"已移出 {payload.peer_id}")


@router.delete(
    "/rooms/{room_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="解散房间（不限房主）",
)
async def delete_room(
    room_id: str, session: SessionDep, hub: HubDep, _: AdminDep
) -> Response:
    room = await room_service.get_room(session, room_id)
    if room is None:
        raise NotFoundError("房间不存在", code="room_not_found")
    await hub.close_room(room_id, reason="closed_by_admin")
    await room_service.delete_room(session, room)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/users", response_model=AdminUserListResponse, summary="账号列表")
async def list_users(
    session: SessionDep,
    hub: HubDep,
    _: AdminDep,
    query: str | None = Query(default=None, max_length=64),
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
) -> AdminUserListResponse:
    users = await accounts.list_users(session, query=query, limit=limit, offset=offset)
    items = [_user_response(user, hub) for user in users]
    return AdminUserListResponse(
        items=items, total=await accounts.count_users(session, query=query)
    )


def _user_response(user: User, hub: SignalingHub) -> AdminUserResponse:
    return AdminUserResponse(
        id=user.id,
        username=user.username,
        display_name=user.display_name,
        created_at=user.created_at,
        online=hub.state.is_user_online(user.id),
        disabled=user.disabled,
    )


@router.get(
    "/music/plugin-subscription",
    response_model=AdminPluginSubscription,
    summary="音乐插件订阅地址",
)
async def get_plugin_subscription(
    store: PluginSubscriptionStoreDep, _: AdminDep
) -> AdminPluginSubscription:
    return AdminPluginSubscription(urls=await store.read())


@router.put(
    "/music/plugin-subscription",
    response_model=AdminPluginSubscription,
    summary="保存音乐插件订阅地址",
)
async def update_plugin_subscription(
    payload: AdminPluginSubscriptionUpdate,
    store: PluginSubscriptionStoreDep,
    _: AdminDep,
) -> AdminPluginSubscription:
    # 校验（http(s):// + .js/.json + 最多 20 条）与保序去重都在 store 里做：
    # 不合法会抛 ValidationError，前端拿到 4xx + code=plugin_subscription_invalid
    return AdminPluginSubscription(urls=await store.write(payload.urls))


async def _get_user_or_404(session: AsyncSession, user_id: int) -> User:
    user = await accounts.get_user(session, user_id)
    if user is None:
        raise NotFoundError("账号不存在", code="user_not_found")
    return user


@router.patch(
    "/users/{user_id}",
    response_model=AdminUserResponse,
    summary="禁用 / 启用账号",
)
async def update_user(
    user_id: int,
    payload: AdminUserUpdate,
    session: SessionDep,
    hub: HubDep,
    _: AdminDep,
) -> AdminUserResponse:
    user = await _get_user_or_404(session, user_id)
    await accounts.set_user_disabled(session, user, disabled=payload.disabled)
    if payload.disabled:
        # 禁用要立刻生效：已签发的令牌会在校验侧被拒，在线会话在这里踢掉
        await hub.kick_user(user.id, reason="account_disabled")
    return _user_response(user, hub)


@router.delete(
    "/users/{user_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    summary="删除账号（连带其房间与好友关系）",
)
async def delete_user(
    user_id: int, session: SessionDep, hub: HubDep, _: AdminDep
) -> Response:
    user = await _get_user_or_404(session, user_id)

    # 先解散他名下的活跃房间：房间里的人会被通知到；否则库里的房间没了，
    # 内存里的房间还挂着人，成员会一直以为自己在通话中
    for room in list(hub.state.live_rooms()):
        if room.owner_id == user.id:
            await hub.close_room(room.room_id, reason="owner_deleted")

    await hub.kick_user(user.id, reason="account_deleted")
    # 房间 / 进房历史 / 好友关系靠外键 ON DELETE CASCADE 一并清理
    await accounts.delete_user(session, user)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post(
    "/users",
    response_model=AdminUserResponse,
    status_code=status.HTTP_201_CREATED,
    summary="创建账号（不受注册开关限制）",
)
async def create_user(
    payload: RegisterRequest, session: SessionDep, hub: HubDep, _: AdminDep
) -> AdminUserResponse:
    if await accounts.get_user_by_username(session, payload.username) is not None:
        raise ConflictError("用户名已被占用", code="username_taken")
    user = await accounts.create_user(
        session,
        username=payload.username,
        password=payload.password,
        display_name=payload.display_name,
        avatar=payload.avatar,
    )
    return _user_response(user, hub)


async def serve_admin_page() -> HTMLResponse:
    """管理页本体（静态 HTML，不含任何密钥；密钥由页面交互时填）。"""
    if not ADMIN_PAGE_PATH.exists():  # pragma: no cover - 镜像里必然存在
        raise NotFoundError("管理页文件缺失", code="admin_page_missing")
    return HTMLResponse(ADMIN_PAGE_PATH.read_text(encoding="utf-8"))


async def serve_admin_logo() -> Response:
    """管理页的品牌图标（无需鉴权：它只是一张图片）。"""
    if not ADMIN_LOGO_PATH.exists():  # pragma: no cover - 镜像里必然存在
        raise NotFoundError("品牌图标缺失", code="admin_logo_missing")
    return Response(
        content=ADMIN_LOGO_PATH.read_bytes(),
        media_type="image/png",
        # 图标不会变，让浏览器缓存一天，省得每次开管理页都重拉
        headers={"Cache-Control": "public, max-age=86400"},
    )


@router.get(
    "/logins",
    response_model=AdminLoginListResponse,
    summary="最近的登录记录（安全审计）",
)
async def login_records(
    _: AdminDep,
    session: SessionDep,
    limit: int = Query(default=50, ge=1, le=200),
    offset: int = Query(default=0, ge=0),
    only_failed: bool = Query(default=False, alias="onlyFailed"),
) -> AdminLoginListResponse:
    """客户端与管理台的登录尝试（成功与失败都在），按时间倒序。"""
    records = await logins.list_logins(
        session, limit=limit, offset=offset, only_failed=only_failed
    )
    return AdminLoginListResponse(
        items=[
            AdminLoginRecordResponse(
                source=record.source,
                username=record.username,
                ip=record.ip,
                user_agent=record.user_agent,
                success=record.success,
                created_at=record.created_at,
            )
            for record in records
        ],
        limit=limit,
        offset=offset,
    )
