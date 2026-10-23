"""统一的业务异常。

响应体统一为 ``{"code": "...", "message": "...", ...}``，便于客户端按 code 分支处理。
``message`` 是给人看的，默认文案走 ``app.core.i18n`` 的多语言表：异常类里不再写字面量，
省得同一条中文在文案表和异常类两处各维护一遍。
"""

from typing import Any

from fastapi import HTTPException, status

from app.core.i18n import t

__all__ = [
    "ApiError",
    "ConflictError",
    "ForbiddenError",
    "NotFoundError",
    "PayloadTooLargeError",
    "TooManyRequestsError",
    "UnauthorizedError",
    "ValidationError",
]


class ApiError(HTTPException):
    """带机器可读 ``code`` 的业务异常。"""

    def __init__(
        self,
        status_code: int,
        code: str,
        message: str,
        *,
        extra: dict[str, Any] | None = None,
    ) -> None:
        super().__init__(status_code=status_code, detail=message)
        self.code = code
        self.message = message
        self.extra = extra or {}
        self.payload: dict[str, Any] = {"code": code, "message": message, **self.extra}


class UnauthorizedError(ApiError):
    def __init__(self, message: str | None = None, code: str = "unauthorized") -> None:
        super().__init__(status.HTTP_401_UNAUTHORIZED, code, message or t("error.unauthorized"))


class ForbiddenError(ApiError):
    def __init__(self, message: str | None = None, code: str = "forbidden") -> None:
        super().__init__(status.HTTP_403_FORBIDDEN, code, message or t("error.forbidden"))


class NotFoundError(ApiError):
    def __init__(self, message: str | None = None, code: str = "not_found") -> None:
        super().__init__(status.HTTP_404_NOT_FOUND, code, message or t("error.not_found"))


class ConflictError(ApiError):
    def __init__(self, message: str | None = None, code: str = "conflict") -> None:
        super().__init__(status.HTTP_409_CONFLICT, code, message or t("error.conflict"))


class PayloadTooLargeError(ApiError):
    def __init__(self, message: str | None = None, code: str = "payload_too_large") -> None:
        super().__init__(
            status.HTTP_413_CONTENT_TOO_LARGE, code, message or t("error.payload_too_large")
        )


class ValidationError(ApiError):
    def __init__(self, message: str | None = None, code: str = "invalid_request") -> None:
        # 注意：Starlette 已弃用 HTTP_422_UNPROCESSABLE_ENTITY，用新名字避免弃用告警
        super().__init__(
            status.HTTP_422_UNPROCESSABLE_CONTENT, code, message or t("error.invalid_request")
        )


class TooManyRequestsError(ApiError):
    """限流：短时间内重试太多次。

    客户端按响应里的 ``retryAfter``（秒）退避后再试即可，不必退出登录。
    """

    def __init__(
        self,
        message: str | None = None,
        *,
        code: str = "too_many_requests",
        retry_after: float = 0.0,
    ) -> None:
        # 向上取整到秒：给 0 秒会客户端立刻又撞一次
        seconds = max(1, round(retry_after + 0.4999)) if retry_after > 0 else 0
        super().__init__(
            status.HTTP_429_TOO_MANY_REQUESTS,
            code,
            message or t("error.too_many_requests"),
            extra={"retryAfter": seconds} if seconds else None,
        )
