"""接口文案的多语言支持：中文（默认）/ 英文 / 日文 / 韩文。

为什么文案集中在这一张表里：返回给客户端的提示散落在接口、依赖、限流与 schema 校验器上，
只有集中一处才可能保证「四种语言都不缺、中文逐字不变」——既有的客户端和测试断言的正是
中文原文，默认语言一旦漂移，整套用例会成片挂掉。

为什么用 contextvars 而不是把 locale 一路当参数传：文案的产生点有十几处，透传要改一圈
函数签名。中间件按 ``Accept-Language`` 选一次，``t()`` 直接从上下文里读当前的 locale。

为什么缺 key 时抛错：``t()`` 返回 key 本身是「看起来没坏、实际全是英文 key」的静默故障，
客户端只会给用户看一串乱码；开发期直接炸掉才能立刻发现漏翻。
"""

from __future__ import annotations

import re
from contextvars import ContextVar, Token
from typing import Final, Literal

from starlette.datastructures import Headers, MutableHeaders
from starlette.types import ASGIApp, Message, Receive, Scope, Send

__all__ = [
    "DEFAULT_LOCALE",
    "MESSAGES",
    "SUPPORTED_LOCALES",
    "Locale",
    "LocaleMiddleware",
    "MissingTextKey",
    "parse_accept_language",
    "reset_current_locale",
    "set_current_locale",
    "t",
]

#: 支持的 locale（顺序即 Accept-Language 无法决定时的偏好顺序：中文优先）
Locale = Literal["zh", "en", "ja", "ko"]

SUPPORTED_LOCALES: Final[tuple[Locale, ...]] = ("zh", "en", "ja", "ko")

#: 默认语言：存量客户端、管理页与全部既有测试断言的都是中文原文
DEFAULT_LOCALE: Final[Locale] = "zh"

#: 主语言子标签 → locale。用表而不是 ``in`` 判断，mypy 才能在 strict 下收窄成 Locale
_LOCALE_BY_PRIMARY: Final[dict[str, Locale]] = {
    "zh": "zh",
    "en": "en",
    "ja": "ja",
    "ko": "ko",
}

#: 合法的主语言子标签（RFC 5646 的 language = 1*8ALPHA）
_PRIMARY_RE: Final = re.compile(r"^[a-z]{1,8}$")


class MissingTextKey(KeyError):
    """文案表里没有这个 key（或这种语言）。继承 KeyError：语义上就是「查不到」。"""


# --------------------------------------------------------------------------- #
# 请求级 locale
# --------------------------------------------------------------------------- #
#: 当前请求的 locale。默认值给中文，所以脱离请求直接用 ``t()``（单元测试、启动期代码）
#: 拿到的一律是中文，不会因为「没设上下文」而变成英文。
_CURRENT_LOCALE: Final[ContextVar[Locale]] = ContextVar("app_locale", default=DEFAULT_LOCALE)


def get_current_locale() -> Locale:
    """当前上下文的 locale。"""
    return _CURRENT_LOCALE.get()


def set_current_locale(locale: Locale) -> Token[Locale]:
    """压入 locale，返回可用于恢复的 token（中间件与测试自己负责 reset）。"""
    return _CURRENT_LOCALE.set(locale)


def reset_current_locale(token: Token[Locale]) -> None:
    """恢复 ``set_current_locale`` 之前的 locale。

    为什么要有这个函数而不是让调用方自己碰上下文变量：``ContextVar.reset()``
    只能拿到变量本身，而 ``_CURRENT_LOCALE`` 是模块私有；WebSocket 端点这类
    「长连接里压一次 locale」的场景必须能干净地还原，否则同一事件循环里后续的
    任务会沿用上一条连接的语言。
    """
    _CURRENT_LOCALE.reset(token)


def parse_accept_language(header: str | None) -> Locale:
    """从 ``Accept-Language`` 选出受支持的语言；无法决定时回落中文。

    规则（按 RFC 7231 的常见子集实现，不引第三方库）：

    * 逗号分隔的每条 ``语言;q=0.9``，按 q 值降序取第一个受支持的语言；
      q 相同时保留出现顺序（``sorted`` 是稳定排序，正好符合这个直觉）。
    * 主语言子标签匹配即可（``zh-CN`` / ``en_US`` 都认：前者按 ``-`` 切，后者先归一化）。
    * q 写坏了（``q=abc``）或 q=0（明确表示「不接受」）的条目整条丢弃。
    * ``*``、空串、不支持的语言、完全不合法的头 → 中文。
    """
    if not header or not header.strip():
        return DEFAULT_LOCALE
    ranked: list[tuple[float, int, Locale]] = []
    for order, chunk in enumerate(header.split(",")):
        tag, _, params = chunk.partition(";")
        quality = _quality(params)
        if quality is None:
            continue
        locale = _supported(tag)
        if locale is None:
            continue
        ranked.append((quality, order, locale))
    if not ranked:
        return DEFAULT_LOCALE
    ranked.sort(key=lambda item: (-item[0], item[1]))
    return ranked[0][2]


def _quality(params: str) -> float | None:
    """解析 ``;q=0.8``；没有 q 参数按 1.0，写坏或 q<=0 返回 None（该条目作废）。"""
    quality = 1.0
    for param in params.split(";"):
        name, _, value = param.partition("=")
        if name.strip().lower() != "q":
            continue
        try:
            quality = float(value.strip())
        except ValueError:
            return None
    if quality <= 0:
        return None
    # RFC 允许的最大值是 1；写大了按 1 处理，不因为头不严谨就把整个请求判成非法
    return min(quality, 1.0)


def _supported(raw: str) -> Locale | None:
    """把一条语言范围映射到受支持的 locale；不支持返回 None。"""
    tag = raw.strip().lower().replace("_", "-")
    if not tag:  # 空条目（``en,,`` 这种）直接跳过
        return None
    primary = tag.split("-", 1)[0]
    if not _PRIMARY_RE.match(primary):
        return None
    return _LOCALE_BY_PRIMARY.get(primary)


def t(key: str, /, *, locale: Locale | None = None, **params: object) -> str:
    """取文案并填占位符（``str.format`` 风格）。

    ``locale`` 省略时用当前请求的 locale（没设就是中文）。占位符参数缺失会由 ``format``
    抛 ``KeyError``，同样是「开发期就炸」，不要靠调用方记住每个占位符。
    """
    entry = MESSAGES.get(key)
    if entry is None:
        raise MissingTextKey(f"文案表里没有 key: {key}")
    template = entry.get(locale or _CURRENT_LOCALE.get())
    if template is None:
        raise MissingTextKey(f"key {key} 缺少语言 {locale!r} 的文案")
    return template.format(**params) if params else template


class LocaleMiddleware:
    """按 ``Accept-Language`` 定本次请求的语言，写进上下文变量并回写 ``Content-Language``。

    写成纯 ASGI 中间件而不是 ``@app.middleware("http")``：BaseHTTPMiddleware 把下游放进
    独立任务里跑，上下文变量要靠任务创建时的上下文复制才能传下去（能work但多一层依赖）；
    这里直接包住下游 app，端点 / 依赖 / 校验器看到的一定是同一个上下文。

    WebSocket 连接不在这里协商：信令端点按查询参数 ``?lang=`` 自己压一次 locale
    （见 ``app.signaling.endpoint``），中间件只对 http scope 生效。
    """

    def __init__(self, app: ASGIApp) -> None:
        self._app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self._app(scope, receive, send)
            return
        locale = parse_accept_language(Headers(scope=scope).get("accept-language"))
        token = set_current_locale(locale)

        async def _send(message: Message) -> None:
            if message["type"] == "http.response.start":
                # 以协商结果为准：不让任何单个接口自己写这个头，避免同一响应里出现两种语言
                MutableHeaders(scope=message)["Content-Language"] = locale
            await send(message)

        try:
            await self._app(scope, receive, _send)
        finally:
            reset_current_locale(token)


# --------------------------------------------------------------------------- #
# 文案表：每个 key 四种语言并列，缺一种就是漏翻（缺语言会抛 MissingTextKey）
# --------------------------------------------------------------------------- #
MESSAGES: Final[dict[str, dict[Locale, str]]] = {
    # ---- 通用错误：app.core.errors 里各异常类的默认文案 ----
    "error.unauthorized": {
        "zh": "未登录或登录状态已过期",
        "en": "Not signed in or the session has expired",
        "ja": "未ログイン、またはログインの有効期限が切れています",
        "ko": "로그인하지 않았거나 로그인 상태가 만료되었습니다",
    },
    "error.forbidden": {
        "zh": "没有权限执行该操作",
        "en": "You are not allowed to perform this action",
        "ja": "この操作を行う権限がありません",
        "ko": "이 작업을 수행할 권한이 없습니다",
    },
    "error.not_found": {
        "zh": "资源不存在",
        "en": "Resource not found",
        "ja": "リソースが見つかりません",
        "ko": "리소스를 찾을 수 없습니다",
    },
    "error.conflict": {
        "zh": "资源冲突",
        "en": "Resource conflict",
        "ja": "リソースが競合しています",
        "ko": "리소스가 충돌합니다",
    },
    "error.payload_too_large": {
        "zh": "内容过大",
        "en": "Payload too large",
        "ja": "データが大きすぎます",
        "ko": "내용이 너무 큽니다",
    },
    "error.invalid_request": {
        "zh": "参数不合法",
        "en": "Invalid parameters",
        "ja": "パラメーターが不正です",
        "ko": "잘못된 매개변수입니다",
    },
    "error.too_many_requests": {
        "zh": "请求过于频繁，请稍后再试",
        "en": "Too many requests, please try again later",
        "ja": "リクエストが多すぎます。しばらくしてから再試行してください",
        "ko": "요청이 너무 많습니다. 잠시 후 다시 시도해 주세요",
    },
    "error.internal": {
        "zh": "服务器内部错误",
        "en": "Internal server error",
        "ja": "サーバー内部エラー",
        "ko": "서버 내부 오류",
    },
    "error.validation_failed": {
        "zh": "参数校验失败",
        "en": "Parameter validation failed",
        "ja": "パラメーターの検証に失敗しました",
        "ko": "매개변수 검증에 실패했습니다",
    },
    # ---- 登录态与账号（app.api.deps / app.api.auth）----
    "auth.token_expired": {
        "zh": "登录状态无效或已过期",
        "en": "The session is invalid or has expired",
        "ja": "ログイン状態が無効か、期限が切れています",
        "ko": "로그인 상태가 유효하지 않거나 만료되었습니다",
    },
    "auth.token_invalid": {
        "zh": "登录状态无效",
        "en": "The session is invalid",
        "ja": "ログイン状態が無効です",
        "ko": "로그인 상태가 유효하지 않습니다",
    },
    "auth.account_missing": {
        "zh": "账号不存在或已注销",
        "en": "The account does not exist or has been deleted",
        "ja": "アカウントが存在しないか、削除されています",
        "ko": "계정이 존재하지 않거나 탈퇴했습니다",
    },
    "auth.account_disabled": {
        "zh": "账号已被管理员禁用",
        "en": "This account has been disabled by the administrator",
        "ja": "このアカウントは管理者によって無効化されています",
        "ko": "이 계정은 관리자에 의해 비활성화되었습니다",
    },
    "auth.password_changed": {
        "zh": "密码已修改，请重新登录",
        "en": "The password was changed, please sign in again",
        "ja": "パスワードが変更されました。再度ログインしてください",
        "ko": "비밀번호가 변경되었습니다. 다시 로그인해 주세요",
    },
    "auth.registration_disabled": {
        "zh": "本服务器未开放注册",
        "en": "Registration is disabled on this server",
        "ja": "このサーバーでは新規登録を受け付けていません",
        "ko": "이 서버는 회원가입을 받지 않습니다",
    },
    "auth.username_taken": {
        "zh": "用户名已被占用",
        "en": "That username is already taken",
        "ja": "このユーザー名は既に使われています",
        "ko": "이미 사용 중인 사용자 이름입니다",
    },
    "auth.login_ip_limited": {
        "zh": "登录请求过于频繁，请 {seconds} 秒后再试",
        "en": "Too many sign-in requests, please try again in {seconds} seconds",
        "ja": "ログイン要求が多すぎます。{seconds} 秒後に再試行してください",
        "ko": "로그인 요청이 너무 많습니다. {seconds}초 후 다시 시도해 주세요",
    },
    "auth.login_backoff": {
        "zh": "该账号输错次数过多，请 {seconds} 秒后再试",
        "en": "Too many failed attempts for this account, please try again in {seconds} seconds",
        "ja": "このアカウントの失敗回数が多すぎます。{seconds} 秒後に再試行してください",
        "ko": "이 계정의 로그인 실패가 너무 많습니다. {seconds}초 후 다시 시도해 주세요",
    },
    "auth.bad_credentials": {
        "zh": "用户名或密码错误",
        "en": "Incorrect username or password",
        "ja": "ユーザー名またはパスワードが正しくありません",
        "ko": "사용자 이름 또는 비밀번호가 올바르지 않습니다",
    },
    "auth.empty_avatar": {
        "zh": "上传内容为空",
        "en": "The uploaded content is empty",
        "ja": "アップロードされた内容が空です",
        "ko": "업로드한 내용이 비어 있습니다",
    },
    "auth.avatar_too_large": {
        "zh": "头像不能超过 {kilobytes} KB",
        "en": "The avatar must not exceed {kilobytes} KB",
        "ja": "アバターは {kilobytes} KB を超えられません",
        "ko": "아바타는 {kilobytes}KB를 초과할 수 없습니다",
    },
    "auth.unsupported_image": {
        "zh": "只支持 PNG / JPEG / WebP / GIF 图片",
        "en": "Only PNG / JPEG / WebP / GIF images are supported",
        "ja": "PNG / JPEG / WebP / GIF 画像のみ対応しています",
        "ko": "PNG / JPEG / WebP / GIF 이미지만 지원합니다",
    },
    "auth.bad_current_password": {
        "zh": "当前密码不正确",
        "en": "The current password is incorrect",
        "ja": "現在のパスワードが正しくありません",
        "ko": "현재 비밀번호가 올바르지 않습니다",
    },
    "auth.password_unchanged": {
        "zh": "新密码不能与当前密码相同",
        "en": "The new password must differ from the current one",
        "ja": "新しいパスワードは現在のパスワードと違うものにしてください",
        "ko": "새 비밀번호는 현재 비밀번호와 달라야 합니다",
    },
    "auth.new_password_too_short": {
        "zh": "新密码至少 {minimum} 位",
        "en": "The new password must be at least {minimum} characters",
        "ja": "新しいパスワードは {minimum} 文字以上にしてください",
        "ko": "새 비밀번호는 최소 {minimum}자 이상이어야 합니다",
    },
    # ---- 口令强度（管理台与注册/登录共用的两套判定）----
    "password.too_short": {
        "zh": "密码至少 {minimum} 位",
        "en": "The password must be at least {minimum} characters",
        "ja": "パスワードは {minimum} 文字以上にしてください",
        "ko": "비밀번호는 최소 {minimum}자 이상이어야 합니다",
    },
    "password.too_long": {
        "zh": "密码过长",
        "en": "The password is too long",
        "ja": "パスワードが長すぎます",
        "ko": "비밀번호가 너무 깁니다",
    },
    "password.too_long_bcrypt": {
        "zh": "密码过长（最多 72 字节）",
        "en": "The password is too long (72 bytes at most)",
        "ja": "パスワードが長すぎます（最大 72 バイト）",
        "ko": "비밀번호가 너무 깁니다 (최대 72바이트)",
    },
    "username.charset": {
        "zh": "用户名只能包含字母、数字、下划线与连字符，长度 3~32",
        "en": (
            "The username may only contain letters, digits, underscores and hyphens, "
            "3 to 32 characters"
        ),
        "ja": "ユーザー名は英数字・アンダースコア・ハイフンのみ、3〜32 文字です",
        "ko": "사용자 이름은 영문, 숫자, 밑줄, 하이픈만 쓸 수 있으며 3~32자입니다",
    },
    # ---- 管理台（app.api.admin）----
    "admin.session_invalid": {
        "zh": "请先登录管理台",
        "en": "Please sign in to the admin console first",
        "ja": "先に管理コンソールへログインしてください",
        "ko": "먼저 관리 콘솔에 로그인해 주세요",
    },
    "admin.bad_token": {
        "zh": "管理令牌不正确",
        "en": "The admin token is incorrect",
        "ja": "管理トークンが正しくありません",
        "ko": "관리 토큰이 올바르지 않습니다",
    },
    "admin.token_retired": {
        "zh": "旧的管理令牌已停用，请用管理员密码登录",
        "en": "The legacy admin token is disabled, please sign in with the admin password",
        "ja": "旧管理トークンは無効になりました。管理者パスワードでログインしてください",
        "ko": "기존 관리 토큰은 더 이상 쓸 수 없습니다. 관리자 비밀번호로 로그인해 주세요",
    },
    "admin.cross_origin_blocked": {
        "zh": "不允许从其他网站调用管理接口，请打开 /admin 操作",
        "en": "Admin APIs cannot be called from other sites, please open /admin instead",
        "ja": "他のサイトから管理 API は呼び出せません。/admin を開いて操作してください",
        "ko": "다른 사이트에서는 관리 API를 호출할 수 없습니다. /admin 을 열어 주세요",
    },
    "admin.already_initialized": {
        "zh": "管理员密码已经设置过了，请直接登录",
        "en": "The admin password is already set, please sign in",
        "ja": "管理者パスワードは設定済みです。そのままログインしてください",
        "ko": "관리자 비밀번호가 이미 설정되어 있습니다. 바로 로그인해 주세요",
    },
    "admin.not_initialized": {
        "zh": "还没有设置管理员密码，请先设置",
        "en": "The admin password has not been set yet, please set it first",
        "ja": "管理者パスワードがまだ設定されていません。先に設定してください",
        "ko": "아직 관리자 비밀번호가 설정되지 않았습니다. 먼저 설정해 주세요",
    },
    "admin.set_password_first": {
        "zh": "请先设置管理员密码",
        "en": "Please set the admin password first",
        "ja": "先に管理者パスワードを設定してください",
        "ko": "먼저 관리자 비밀번호를 설정해 주세요",
    },
    "admin.locked": {
        "zh": "密码错误次数过多，请 {seconds} 秒后再试",
        "en": "Too many incorrect passwords, please try again in {seconds} seconds",
        "ja": "パスワードの誤りが多すぎます。{seconds} 秒後に再試行してください",
        "ko": "비밀번호 오류가 너무 많습니다. {seconds}초 후 다시 시도해 주세요",
    },
    "admin.bad_password": {
        "zh": "管理员密码不正确",
        "en": "The admin password is incorrect",
        "ja": "管理者パスワードが正しくありません",
        "ko": "관리자 비밀번호가 올바르지 않습니다",
    },
    "admin.peer_offline": {
        "zh": "该会话已离线",
        "en": "That session is already offline",
        "ja": "そのセッションは既にオフラインです",
        "ko": "해당 세션은 이미 오프라인입니다",
    },
    "admin.peer_not_in_room": {
        "zh": "该会话不在指定房间内",
        "en": "That session is not in the specified room",
        "ja": "そのセッションは指定されたルームにいません",
        "ko": "해당 세션은 지정한 방에 없습니다",
    },
    "admin.peer_kicked": {
        "zh": "已移出 {peer_id}",
        "en": "Removed {peer_id}",
        "ja": "{peer_id} を退出させました",
        "ko": "{peer_id} 를 내보냈습니다",
    },
    "admin.user_not_found": {
        "zh": "账号不存在",
        "en": "Account not found",
        "ja": "アカウントが見つかりません",
        "ko": "계정을 찾을 수 없습니다",
    },
    "admin.page_missing": {
        "zh": "管理页文件缺失",
        "en": "The admin page file is missing",
        "ja": "管理ページのファイルが見つかりません",
        "ko": "관리 페이지 파일이 없습니다",
    },
    "admin.logo_missing": {
        "zh": "品牌图标缺失",
        "en": "The brand logo file is missing",
        "ja": "ブランドロゴのファイルが見つかりません",
        "ko": "브랜드 로고 파일이 없습니다",
    },
    # ---- 房间（app.api.rooms）----
    "room.not_found": {
        "zh": "房间不存在",
        "en": "Room not found",
        "ja": "ルームが見つかりません",
        "ko": "방을 찾을 수 없습니다",
    },
    "room.owner_only_update": {
        "zh": "只有房主可以修改房间",
        "en": "Only the room owner can edit the room",
        "ja": "ルームを変更できるのはオーナーだけです",
        "ko": "방 주인만 방을 수정할 수 있습니다",
    },
    "room.owner_only_delete": {
        "zh": "只有房主可以解散房间",
        "en": "Only the room owner can close the room",
        "ja": "ルームを解散できるのはオーナーだけです",
        "ko": "방 주인만 방을 해산할 수 있습니다",
    },
    # ---- 头像（app.api.avatars）----
    "avatar.not_found": {
        "zh": "头像不存在",
        "en": "Avatar not found",
        "ja": "アバターが見つかりません",
        "ko": "아바타를 찾을 수 없습니다",
    },
    # ---- 好友（app.api.friends / app.services.friends）----
    "friends.user_not_found": {
        "zh": "用户不存在",
        "en": "User not found",
        "ja": "ユーザーが見つかりません",
        "ko": "사용자를 찾을 수 없습니다",
    },
    "friends.already_friends": {
        "zh": "你们已经是好友",
        "en": "You are already friends",
        "ja": "すでにフレンドです",
        "ko": "이미 친구입니다",
    },
    "friends.duplicate_request": {
        "zh": "已发送过申请，等待对方处理",
        "en": "The request was already sent, waiting for the other side",
        "ja": "申請済みです。相手の対応をお待ちください",
        "ko": "이미 요청을 보냈습니다. 상대방의 처리를 기다려 주세요",
    },
    "friends.request_not_found": {
        "zh": "申请不存在或已处理",
        "en": "The request does not exist or was already handled",
        "ja": "申請が見つからないか、すでに処理済みです",
        "ko": "요청이 없거나 이미 처리되었습니다",
    },
    "friends.not_friends": {
        "zh": "你们还不是好友",
        "en": "You are not friends yet",
        "ja": "まだフレンドではありません",
        "ko": "아직 친구가 아닙니다",
    },
    "friends.cannot_add_self": {
        "zh": "不能添加自己为好友",
        "en": "You cannot add yourself as a friend",
        "ja": "自分自身をフレンドに追加することはできません",
        "ko": "자기 자신을 친구로 추가할 수 없습니다",
    },
    # ---- 音乐插件订阅地址（app.services.plugin_subscription）----
    # plugin.position 先拼出「第几条」，其余 key 再把它当参数插进句子里：
    # 中英日韩的语序不同，所以只能先拼好「第 N 条订阅地址」这一段，不能拆开翻译
    "plugin.position": {
        "zh": "第 {index} 条订阅地址",
        "en": "subscription #{index}",
        "ja": "{index} 番目の購読 URL",
        "ko": "{index}번째 구독 URL",
    },
    "plugin.position_not_string": {
        "zh": "{position}必须是字符串",
        "en": "{position} must be a string",
        "ja": "{position}は文字列である必要があります",
        "ko": "{position} 항목은 문자열이어야 합니다",
    },
    "plugin.position_empty": {
        "zh": "{position}为空",
        "en": "{position} is empty",
        "ja": "{position}が空です",
        "ko": "{position} 항목이 비어 있습니다",
    },
    "plugin.position_too_long": {
        "zh": "{position}过长（{length} 字符，最多 {maximum}）",
        "en": "{position} is too long ({length} characters, at most {maximum})",
        "ja": "{position}が長すぎます（{length} 文字、最大 {maximum} 文字）",
        "ko": "{position} 항목이 너무 깁니다 ({length}자, 최대 {maximum}자)",
    },
    "plugin.position_not_absolute": {
        "zh": "{position}不是 http:// 或 https:// 开头的绝对地址：{url}",
        "en": "{position} is not an absolute URL starting with http:// or https://: {url}",
        "ja": "{position}が http:// または https:// で始まる絶対 URL ではありません：{url}",
        "ko": "{position} 항목이 http:// 또는 https:// 로 시작하는 절대 주소가 아닙니다: {url}",
    },
    "plugin.position_bad_suffix": {
        "zh": "{position}必须以 .js 或 .json 结尾（插件订阅地址）：{url}",
        "en": "{position} must end with .js or .json (plugin subscription URL): {url}",
        "ja": "{position}は .js または .json で終わる必要があります（プラグイン購読 URL）：{url}",
        "ko": "{position} 항목은 .js 또는 .json 으로 끝나야 합니다 (플러그인 구독 주소): {url}",
    },
    "plugin.too_many": {
        "zh": "最多只能保存 {maximum} 条订阅地址（当前 {count} 条）",
        "en": "At most {maximum} subscription URLs can be saved (currently {count})",
        "ja": "保存できる購読 URL は最大 {maximum} 件です（現在 {count} 件）",
        "ko": "구독 주소는 최대 {maximum}개까지 저장할 수 있습니다 (현재 {count}개)",
    },
    # ---- 信令 WebSocket（app.signaling.hub / app.signaling.music）----
    # 这些文案走信令的 ``error.message`` 字段直接显示在客户端界面上；语言由连接时的
    # ``?lang=`` 决定（见 app.signaling.endpoint），中文保持改动前的原文。
    "ws.invalid_json": {
        "zh": "消息不是合法的 JSON",
        "en": "The message is not valid JSON",
        "ja": "メッセージが正しい JSON ではありません",
        "ko": "메시지가 올바른 JSON이 아닙니다",
    },
    "ws.unsupported_message": {
        "zh": "不支持的消息类型",
        "en": "Unsupported message type",
        "ja": "サポートされていないメッセージ種別です",
        "ko": "지원하지 않는 메시지 유형입니다",
    },
    "ws.already_in_room": {
        "zh": "已经在一个房间中",
        "en": "You are already in a room",
        "ja": "すでにルームに参加しています",
        "ko": "이미 룸에 참여해 있습니다",
    },
    "ws.room_not_found": {
        "zh": "房间不存在",
        "en": "Room not found",
        "ja": "ルームが見つかりません",
        "ko": "룸을 찾을 수 없습니다",
    },
    "ws.bad_password": {
        "zh": "房间密码错误",
        "en": "Incorrect room password",
        "ja": "ルームのパスワードが正しくありません",
        "ko": "룸 비밀번호가 올바르지 않습니다",
    },
    "ws.room_full": {
        "zh": "房间已满",
        "en": "The room is full",
        "ja": "ルームが満員です",
        "ko": "룸 정원이 가득 찼습니다",
    },
    "ws.not_in_room": {
        "zh": "尚未加入房间",
        "en": "You have not joined a room yet",
        "ja": "まだルームに参加していません",
        "ko": "아직 룸에 참여하지 않았습니다",
    },
    "ws.peer_unavailable": {
        "zh": "对端不在线或不在同一房间",
        "en": "The peer is offline or not in the same room",
        "ja": "相手がオフラインか、同じルームにいません",
        "ko": "상대가 오프라인이거나 같은 룸에 없습니다",
    },
    "ws.music_disabled": {
        "zh": "服务器没有开启点歌",
        "en": "The jukebox is disabled on this server",
        "ja": "このサーバーではジュークボックスが有効になっていません",
        "ko": "이 서버에서는 주크박스가 활성화되어 있지 않습니다",
    },
    # schema 校验失败：字段名与 pydantic 的原始描述保持原样，只翻译外壳
    "ws.validation_failed": {
        "zh": "校验失败",
        "en": "Validation failed",
        "ja": "検証に失敗しました",
        "ko": "검증에 실패했습니다",
    },
    "ws.field_validation": {
        "zh": "字段 {field}: {reason}",
        "en": "Field {field}: {reason}",
        "ja": "フィールド {field}: {reason}",
        "ko": "필드 {field}: {reason}",
    },
    # ---- 点歌台：入队与控制的拒绝原因 ----
    "ws.music_rate_limited": {
        "zh": "点歌太快了，{wait} 秒后再试",
        "en": "You are requesting songs too fast, please try again in {wait} seconds",
        "ja": "曲のリクエストが速すぎます。{wait} 秒後に再試行してください",
        "ko": "노래 신청이 너무 빠릅니다. {wait}초 후 다시 시도해 주세요",
    },
    "ws.music_info_too_large": {
        "zh": "歌曲信息太大（{size} 字节，上限 {limit}）",
        "en": "The song data is too large ({size} bytes, limit {limit})",
        "ja": "曲の情報が大きすぎます（{size} バイト、上限 {limit} バイト）",
        "ko": "노래 정보가 너무 큽니다 ({size}바이트, 최대 {limit}바이트)",
    },
    "ws.music_queue_full": {
        "zh": "点歌队列已满，等会儿再点",
        "en": "The jukebox queue is full, please try again later",
        "ja": "ジュークボックスのキューが満杯です。しばらくしてからリクエストしてください",
        "ko": "주크박스 대기열이 가득 찼습니다. 잠시 후 다시 신청해 주세요",
    },
    "ws.music_personal_limit": {
        "zh": "每人最多同时点 {limit} 首，等自己的歌播完再点",
        "en": "Each person can queue at most {limit} songs, please wait until yours finish",
        "ja": "同時にリクエストできるのは 1 人 {limit} 曲まで。自分の曲が終わるまでお待ちください",
        "ko": "1인당 최대 {limit}곡까지 신청할 수 있습니다. 자신의 노래가 끝난 후 신청해 주세요",
    },
    "ws.music_duplicate_entry": {
        "zh": "这首歌已经在队列里了",
        "en": "This song is already in the queue",
        "ja": "この曲はすでにキューに入っています",
        "ko": "이 노래는 이미 대기열에 있습니다",
    },
    "ws.music_remove_others": {
        "zh": "只能删除自己点的歌",
        "en": "You can only remove the songs you requested",
        "ja": "削除できるのは自分がリクエストした曲だけです",
        "ko": "자신이 신청한 노래만 삭제할 수 있습니다",
    },
    "ws.music_entry_missing": {
        "zh": "这首歌已经不在队列里了",
        "en": "This song is no longer in the queue",
        "ja": "この曲はもうキューにありません",
        "ko": "이 노래는 더 이상 대기열에 없습니다",
    },
    "ws.music_nothing_playing": {
        "zh": "现在没有正在播放的歌",
        "en": "Nothing is playing right now",
        "ja": "現在再生中の曲はありません",
        "ko": "현재 재생 중인 노래가 없습니다",
    },
    "ws.music_not_current": {
        "zh": "这首歌已经不是当前曲了",
        "en": "This song is no longer the current track",
        "ja": "この曲はもう再生中の曲ではありません",
        "ko": "이 노래는 더 이상 현재 재생 곡이 아닙니다",
    },
    "ws.music_clear_owner_only": {
        "zh": "只有房主可以清空队列",
        "en": "Only the room owner can clear the queue",
        "ja": "キューをクリアできるのはルームのオーナーだけです",
        "ko": "룸 주인만 대기열을 비울 수 있습니다",
    },
    "ws.music_skip_forbidden": {
        "zh": "只有房主或点歌人可以切歌",
        "en": "Only the room owner or the requester can skip this song",
        "ja": "この曲をスキップできるのはルームのオーナーまたはリクエストした本人だけです",
        "ko": "룸 주인 또는 신청자만 이 노래를 건너뛸 수 있습니다",
    },
    "ws.music_bad_mode": {
        "zh": "不支持的播放模式：{mode}",
        "en": "Unsupported play mode: {mode}",
        "ja": "サポートされていない再生モードです：{mode}",
        "ko": "지원하지 않는 재생 모드입니다: {mode}",
    },
}
