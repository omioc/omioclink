"""FastAPI 依赖注入。"""

from collections.abc import AsyncIterator
from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.core.config import Settings, get_settings
from app.core.errors import UnauthorizedError
from app.core.ratelimit import LoginLimits
from app.core.security import decode_access_token, password_fingerprint
from app.db.models import User
from app.services import accounts
from app.services.avatars import AvatarStore
from app.services.plugin_subscription import PluginSubscriptionStore
from app.signaling.hub import SignalingHub

__all__ = [
    "AvatarStoreDep",
    "CurrentUser",
    "HubDep",
    "LoginLimitsDep",
    "OptionalUser",
    "PluginSubscriptionStoreDep",
    "SessionDep",
    "SettingsDep",
    "bearer_scheme",
    "get_avatar_store",
    "get_hub",
    "get_login_limits",
    "get_plugin_subscription_store",
    "get_session",
    "get_settings_dep",
    "resolve_token_user",
]

bearer_scheme = HTTPBearer(auto_error=False, description="登录获取的 JWT")


def get_settings_dep(request: Request) -> Settings:
    settings: Settings | None = getattr(request.app.state, "settings", None)
    return settings if settings is not None else get_settings()


def get_hub(request: Request) -> SignalingHub:
    hub: SignalingHub = request.app.state.hub
    return hub


def get_avatar_store(request: Request) -> AvatarStore:
    store: AvatarStore = request.app.state.avatars
    return store


def get_plugin_subscription_store(request: Request) -> PluginSubscriptionStore:
    store: PluginSubscriptionStore = request.app.state.plugin_subscription
    return store


def get_login_limits(request: Request) -> LoginLimits:
    limits: LoginLimits = request.app.state.login_limits
    return limits


async def get_session(request: Request) -> AsyncIterator[AsyncSession]:
    factory: async_sessionmaker[AsyncSession] = request.app.state.session_factory
    async with factory() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise


SettingsDep = Annotated[Settings, Depends(get_settings_dep)]
SessionDep = Annotated[AsyncSession, Depends(get_session)]
HubDep = Annotated[SignalingHub, Depends(get_hub)]
AvatarStoreDep = Annotated[AvatarStore, Depends(get_avatar_store)]
PluginSubscriptionStoreDep = Annotated[
    PluginSubscriptionStore, Depends(get_plugin_subscription_store)
]
CredentialsDep = Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)]
LoginLimitsDep = Annotated[LoginLimits, Depends(get_login_limits)]


async def resolve_token_user(session: AsyncSession, settings: Settings, token: str | None) -> User:
    """把 JWT 换成用户；失败抛 401。"""
    if not token:
        raise UnauthorizedError
    payload = decode_access_token(
        token, secret=settings.jwt_secret, algorithm=settings.jwt_algorithm
    )
    if payload is None:
        raise UnauthorizedError("登录状态无效或已过期")
    try:
        user_id = int(payload["sub"])
    except (KeyError, TypeError, ValueError) as exc:
        raise UnauthorizedError("登录状态无效") from exc
    user = await accounts.get_user(session, user_id)
    if user is None:
        raise UnauthorizedError("账号不存在或已注销")
    if user.disabled:
        # 被禁用的账号，已签发的令牌立即失效（客户端收到 401 后会退出登录）
        raise UnauthorizedError("账号已被管理员禁用", code="account_disabled")
    expected = password_fingerprint(
        secret=settings.jwt_secret, password_hash=user.password_hash
    )
    if payload.get("pwf") != expected:
        # 口令改过（或令牌签发于本机制之前）：旧令牌一律失效。
        # 改密码的那台设备会拿到新令牌，其他设备下次请求即被登出。
        raise UnauthorizedError("密码已修改，请重新登录", code="token_revoked")
    return user


async def get_current_user(
    session: SessionDep,
    settings: SettingsDep,
    credentials: CredentialsDep = None,
) -> User:
    token = credentials.credentials if credentials is not None else None
    return await resolve_token_user(session, settings, token)


async def get_optional_user(
    session: SessionDep,
    settings: SettingsDep,
    credentials: CredentialsDep = None,
) -> User | None:
    token = credentials.credentials if credentials is not None else None
    if not token:
        return None
    try:
        return await resolve_token_user(session, settings, token)
    except UnauthorizedError:
        return None


CurrentUser = Annotated[User, Depends(get_current_user)]
OptionalUser = Annotated[User | None, Depends(get_optional_user)]
