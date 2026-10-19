"""账号接口：注册、登录、资料、头像。"""

from fastapi import APIRouter, UploadFile, status

from app.api.deps import (
    AvatarStoreDep,
    CurrentUser,
    HubDep,
    SessionDep,
    SettingsDep,
)
from app.api.serializers import user_profile
from app.core.config import Settings
from app.core.errors import (
    ConflictError,
    ForbiddenError,
    PayloadTooLargeError,
    UnauthorizedError,
    ValidationError,
)
from app.core.security import (
    create_access_token,
    password_fingerprint,
    verify_password,
)
from app.db.models import User
from app.schemas import (
    LoginRequest,
    PasswordChangeRequest,
    RegisterRequest,
    TokenResponse,
    UpdateProfileRequest,
    UserProfile,
)
from app.services import accounts
from app.services.avatars import UnsupportedImageError

router = APIRouter(prefix="/auth", tags=["账号"])


def _issue_token(user: User, settings: Settings, *, online: bool = False) -> TokenResponse:
    token = create_access_token(
        user_id=user.id,
        username=user.username,
        secret=settings.jwt_secret,
        algorithm=settings.jwt_algorithm,
        ttl_seconds=settings.access_token_ttl_seconds,
        password_fingerprint=password_fingerprint(
            secret=settings.jwt_secret, password_hash=user.password_hash
        ),
    )
    return TokenResponse(
        access_token=token,
        expires_in=settings.access_token_ttl_seconds,
        user=user_profile(user, online=online),
    )


@router.post(
    "/register",
    response_model=TokenResponse,
    status_code=status.HTTP_201_CREATED,
    summary="注册并直接登录（需要服务器开放注册）",
)
async def register(
    payload: RegisterRequest, session: SessionDep, settings: SettingsDep
) -> TokenResponse:
    # 先判开关再查重名：关闭注册时不泄露「某个用户名是否已存在」
    if not settings.allow_registration:
        raise ForbiddenError("本服务器未开放注册", code="registration_disabled")
    if await accounts.get_user_by_username(session, payload.username) is not None:
        raise ConflictError("用户名已被占用", code="username_taken")
    user = await accounts.create_user(
        session,
        username=payload.username,
        password=payload.password,
        display_name=payload.display_name,
        avatar=payload.avatar,
    )
    return _issue_token(user, settings)


@router.post("/login", response_model=TokenResponse, summary="登录")
async def login(
    payload: LoginRequest, session: SessionDep, settings: SettingsDep, hub: HubDep
) -> TokenResponse:
    user = await accounts.authenticate(session, payload.username, payload.password)
    if user is None:
        raise UnauthorizedError("用户名或密码错误", code="bad_credentials")
    if user.disabled:
        raise ForbiddenError("账号已被管理员禁用", code="account_disabled")
    return _issue_token(user, settings, online=hub.state.is_user_online(user.id))


@router.get("/me", response_model=UserProfile, summary="当前账号资料")
async def me(user: CurrentUser, hub: HubDep) -> UserProfile:
    return user_profile(user, online=hub.state.is_user_online(user.id))


@router.patch("/me", response_model=UserProfile, summary="修改昵称/头像")
async def update_me(
    payload: UpdateProfileRequest, user: CurrentUser, session: SessionDep, hub: HubDep
) -> UserProfile:
    updated = await accounts.update_profile(
        session, user, display_name=payload.display_name
    )
    if payload.display_name is not None:
        # 库里已经改了，这里把在线房间里的那条成员记录一并换掉并广播，
        # 同房间的人立刻就能看到新昵称，不需要退出重进
        await hub.sync_user_profile(
            updated.id, display_name=updated.display_name, avatar=updated.avatar
        )
    return user_profile(updated, online=hub.state.is_user_online(updated.id))


@router.post("/avatar", response_model=UserProfile, summary="上传头像（PNG/JPEG/WebP/GIF）")
async def upload_avatar(
    user: CurrentUser,
    session: SessionDep,
    settings: SettingsDep,
    hub: HubDep,
    store: AvatarStoreDep,
    file: UploadFile,
) -> UserProfile:
    # 分块读取时多读一个字节：正好用它判断「超限」而不是「刚好等于上限」
    data = await file.read(settings.avatar_max_bytes + 1)
    await file.close()
    if not data:
        raise ValidationError("上传内容为空", code="empty_avatar")
    if len(data) > settings.avatar_max_bytes:
        raise PayloadTooLargeError(
            f"头像不能超过 {settings.avatar_max_bytes // 1024} KB",
            code="avatar_too_large",
        )
    try:
        version = store.save(user.id, data)
    except UnsupportedImageError as exc:
        # 不信任 Content-Type 与文件名后缀，只认文件头
        raise ValidationError(
            "只支持 PNG / JPEG / WebP / GIF 图片", code="unsupported_image"
        ) from exc

    user.avatar = version
    await session.flush()
    await hub.sync_user_profile(
        user.id, display_name=user.display_name, avatar=version
    )
    return user_profile(user, online=hub.state.is_user_online(user.id))


@router.delete("/avatar", response_model=UserProfile, summary="移除头像")
async def delete_avatar(
    user: CurrentUser, session: SessionDep, hub: HubDep, store: AvatarStoreDep
) -> UserProfile:
    store.remove(user.id)
    user.avatar = None
    await session.flush()
    await hub.sync_user_profile(user.id, display_name=user.display_name, avatar=None)
    return user_profile(user, online=hub.state.is_user_online(user.id))


@router.post(
    "/password",
    response_model=TokenResponse,
    summary="修改密码（其他设备会被登出）",
)
async def change_password(
    payload: PasswordChangeRequest,
    user: CurrentUser,
    session: SessionDep,
    settings: SettingsDep,
) -> TokenResponse:
    # 用 403 而不是 401：401 会被客户端当作「登录态失效」而触发退出登录，
    # 但这里只是表单里的当前密码填错了，账号本身完全有效。
    if not verify_password(payload.current_password, user.password_hash):
        raise ForbiddenError("当前密码不正确", code="bad_current_password")
    if payload.new_password == payload.current_password:
        raise ValidationError("新密码不能与当前密码相同", code="password_unchanged")
    minimum = settings.password_min_length
    if len(payload.new_password) < minimum:
        raise ValidationError(f"新密码至少 {minimum} 位", code="weak_password")
    await accounts.change_password(session, user, payload.new_password)
    # 口令变了 → 此前签发的令牌全部失效；这台设备顺手换一张新令牌，不必重新登录
    return _issue_token(user, settings)
