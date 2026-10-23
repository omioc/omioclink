"""API 文案多语言：Accept-Language 协商、四语错误文案、Content-Language 响应头。

覆盖三层：纯函数（``parse_accept_language``）、文案表自身的一致性、以及真实 HTTP 层
（同一个接口在四种语言下返回的 message 与响应头）。第三层不能省——签名对了不代表
中间件真的把 locale 传到了产生文案的地方（依赖、校验器、限流都在不同的调用点）。
"""

import re
from pathlib import Path
from string import Formatter

import pytest
from fastapi.testclient import TestClient

from app.core.i18n import (
    DEFAULT_LOCALE,
    MESSAGES,
    SUPPORTED_LOCALES,
    Locale,
    MissingTextKey,
    get_current_locale,
    parse_accept_language,
    t,
)
from app.main import create_app
from tests.conftest import PASSWORD, make_settings, register_user

#: 登录限流用的韩文文案（连数字一起断言，顺手验证占位符真的被填上了）
_KO_LOGIN_LIMITED = re.compile(r"^로그인 요청이 너무 많습니다\. (\d+)초 후 다시 시도해 주세요$")


@pytest.mark.parametrize(
    ("header", "expected"),
    [
        # 缺失 / 空 / 全是垃圾：中文
        (None, "zh"),
        ("", "zh"),
        ("   ", "zh"),
        (";;;", "zh"),
        # 通配符不指定具体语言：中文
        ("*", "zh"),
        # 带地区子标签、大小写、下划线都要认
        ("en", "en"),
        ("en-US", "en"),
        ("en_US", "en"),
        ("EN-GB", "en"),
        # q 值排序：zh 隐含 1.0，高于 en 的 0.8
        ("zh-CN,zh;q=0.9,en;q=0.8", "zh"),
        ("ja;q=0.9,ko;q=0.95", "ko"),
        # q 相同按出现顺序
        ("ko, en;q=1.0", "ko"),
        # 全都不支持：回落中文
        ("fr-FR,de;q=0.8", "zh"),
        # q=0 表示「明确不接受」，跳过它取下一个
        ("en;q=0,ja;q=0.5", "ja"),
        # 只取 q 最高的受支持语言，后面的不参与
        ("de;q=0.9,en;q=0.1", "en"),
        # q 写坏：整条丢弃
        ("en;q=abc", "zh"),
        # q 超过 1 按 1 处理，不因此判成非法
        ("en;q=2", "en"),
        ("ja-JP;q=0.7, zh-TW;q=0.6", "ja"),
    ],
)
def test_解析_accept_language(header: str | None, expected: Locale) -> None:
    assert parse_accept_language(header) == expected


def test_文案表四语齐全且占位符一致() -> None:
    """缺语言是漏翻，缺占位符是运行时 KeyError（线上会变成 500），都要在测试里拦下。"""
    formatter = Formatter()
    for key, entry in MESSAGES.items():
        assert set(entry) == set(SUPPORTED_LOCALES), f"{key} 的语言不全：{sorted(entry)}"
        placeholders = {}
        for locale in SUPPORTED_LOCALES:
            template = entry[locale]
            assert template.strip(), f"{key} 的 {locale} 文案是空的"
            placeholders[locale] = {
                name for _, name, _, _ in formatter.parse(template) if name is not None
            }
        assert len({frozenset(names) for names in placeholders.values()}) == 1, (
            f"{key} 的占位符四语不一致：{placeholders}"
        )


def test_缺_key时抛错而不是静默返回_key() -> None:
    """返回 key 本身只会让客户端给用户看一串英文 key，开发期必须立刻炸。"""
    with pytest.raises(MissingTextKey):
        t("no.such.key")


def test_没有请求上下文时默认中文() -> None:
    assert get_current_locale() == DEFAULT_LOCALE
    assert t("error.internal") == "服务器内部错误"
    assert t("error.internal", locale="en") == "Internal server error"


def test_响应头带协商结果且默认中文(client: TestClient) -> None:
    default = client.get("/api/v1/health")
    assert default.status_code == 200
    assert default.headers["content-language"] == "zh"

    english = client.get("/api/v1/health", headers={"Accept-Language": "en-US,en;q=0.9"})
    assert english.headers["content-language"] == "en"

    # 不支持的语言同样回落中文（客户端据此显示的语言与 message 一致）
    unknown = client.get("/api/v1/health", headers={"Accept-Language": "fr"})
    assert unknown.headers["content-language"] == "zh"


@pytest.mark.parametrize("locale", SUPPORTED_LOCALES)
def test_未登录提示四种语言(client: TestClient, locale: Locale) -> None:
    response = client.get("/api/v1/auth/me", headers={"Accept-Language": locale})
    assert response.status_code == 401, response.text
    body = response.json()
    assert body["code"] == "unauthorized"
    assert body["message"] == t("error.unauthorized", locale=locale)
    assert response.headers["content-language"] == locale


@pytest.mark.parametrize("locale", SUPPORTED_LOCALES)
def test_令牌无效提示四种语言(client: TestClient, locale: Locale) -> None:
    """带了但解不开的令牌走另一条文案（跟「根本没带」区分开）。"""
    response = client.get(
        "/api/v1/auth/me",
        headers={"Accept-Language": locale, "Authorization": "Bearer not-a-jwt"},
    )
    assert response.status_code == 401, response.text
    body = response.json()
    assert body["code"] == "unauthorized"
    assert body["message"] == t("auth.token_expired", locale=locale)
    assert response.headers["content-language"] == locale


def test_没带_accept_language_时就是改动前的中文原文(client: TestClient) -> None:
    body = client.get("/api/v1/auth/me").json()
    assert body["message"] == "未登录或登录状态已过期"


@pytest.mark.parametrize("locale", SUPPORTED_LOCALES)
def test_房间不存在四种语言(client: TestClient, locale: Locale) -> None:
    response = client.get("/api/v1/rooms/not-a-room", headers={"Accept-Language": locale})
    assert response.status_code == 404, response.text
    body = response.json()
    assert body["code"] == "room_not_found"
    assert body["message"] == t("room.not_found", locale=locale)
    assert response.headers["content-language"] == locale


@pytest.mark.parametrize("locale", SUPPORTED_LOCALES)
def test_关闭注册四种语言(tmp_path: Path, locale: Locale) -> None:
    """注册开关的 403 是「跟语言无关的业务规则」，四种语言下都得对上同一套文案。"""
    app = create_app(make_settings(tmp_path, allow_registration=False))
    with TestClient(app) as client:
        response = client.post(
            "/api/v1/auth/register",
            json={"username": "alice", "password": PASSWORD},
            headers={"Accept-Language": locale},
        )
    assert response.status_code == 403, response.text
    body = response.json()
    assert body["code"] == "registration_disabled"
    assert body["message"] == t("auth.registration_disabled", locale=locale)
    # 中文是最不能变的那个：既有客户端与用例断言的正是逐字原文
    if locale == "zh":
        assert body["message"] == "本服务器未开放注册"


def test_校验提示跟随语言(client: TestClient) -> None:
    """schema 校验器里的文案在 pydantic 里抛出，同样要能读到请求的 locale。"""
    response = client.post(
        "/api/v1/auth/register",
        json={"username": "bad name", "password": PASSWORD},
        headers={"Accept-Language": "en"},
    )
    assert response.status_code == 422, response.text
    body = response.json()
    assert body["code"] == "invalid_request"
    assert t("username.charset", locale="en") in body["message"]
    assert response.headers["content-language"] == "en"


def test_登录限流文案跟随语言(client: TestClient) -> None:
    register_user(client, "alice")
    headers = {"Accept-Language": "ko"}
    payload = {"username": "alice", "password": PASSWORD}
    for _ in range(10):
        assert client.post("/api/v1/auth/login", json=payload, headers=headers).status_code == 200

    limited = client.post("/api/v1/auth/login", json=payload, headers=headers)
    assert limited.status_code == 429, limited.text
    body = limited.json()
    assert body["code"] == "login_rate_limited"
    assert body["retryAfter"] >= 1
    assert _KO_LOGIN_LIMITED.match(body["message"]), body["message"]
    assert limited.headers["content-language"] == "ko"


def test_未处理异常也有语言与响应头(tmp_path: Path) -> None:
    """500 兜底处理器比中间件还外层，得自己按请求头重新协商语言。"""
    app = create_app(make_settings(tmp_path))

    @app.get("/boom")
    async def boom() -> None:
        raise RuntimeError("boom")

    with TestClient(app, raise_server_exceptions=False) as client:
        response = client.get("/boom", headers={"Accept-Language": "ja"})
    assert response.status_code == 500
    body = response.json()
    assert body["code"] == "internal_error"
    assert body["message"] == t("error.internal", locale="ja")
    assert response.headers["content-language"] == "ja"


def test_locale_不会泄漏到下一次请求(client: TestClient) -> None:
    korean = client.get("/api/v1/health", headers={"Accept-Language": "ko"})
    assert korean.headers["content-language"] == "ko"
    # 上下文变量在中间件 finally 里 reset：下一条没带头的请求必须回到中文
    assert client.get("/api/v1/health").headers["content-language"] == "zh"
