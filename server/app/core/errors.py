"""统一的业务异常。

响应体统一为 ``{"code": "...", "message": "...", ...}``，便于客户端按 code 分支处理。
"""

from typing import Any

from fastapi import HTTPException, status

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
    def __init__(self, message: str = "未登录或登录状态已过期", code: str = "unauthorized") -> None:
        super().__init__(status.HTTP_401_UNAUTHORIZED, code, message)


class ForbiddenError(ApiError):
    def __init__(self, message: str = "没有权限执行该操作", code: str = "forbidden") -> None:
        super().__init__(status.HTTP_403_FORBIDDEN, code, message)


class NotFoundError(ApiError):
    def __init__(self, message: str = "资源不存在", code: str = "not_found") -> None:
        super().__init__(status.HTTP_404_NOT_FOUND, code, message)


class ConflictError(ApiError):
    def __init__(self, message: str = "资源冲突", code: str = "conflict") -> None:
        super().__init__(status.HTTP_409_CONFLICT, code, message)


class PayloadTooLargeError(ApiError):
    def __init__(self, message: str = "内容过大", code: str = "payload_too_large") -> None:
        super().__init__(status.HTTP_413_CONTENT_TOO_LARGE, code, message)


class ValidationError(ApiError):
    def __init__(self, message: str = "参数不合法", code: str = "invalid_request") -> None:
        # 注意：Starlette 已弃用 HTTP_422_UNPROCESSABLE_ENTITY，用新名字避免弃用告警
        super().__init__(status.HTTP_422_UNPROCESSABLE_CONTENT, code, message)


class TooManyRequestsError(ApiError):
    """限流：短时间内重试太多次。

    客户端按响应里的 ``retryAfter``（秒）退避后再试即可，不必退出登录。
    """

    def __init__(
        self,
        message: str = "请求过于频繁，请稍后再试",
        *,
        code: str = "too_many_requests",
        retry_after: float = 0.0,
    ) -> None:
        # 向上取整到秒：给 0 秒会客户端立刻又撞一次
        seconds = max(1, round(retry_after + 0.4999)) if retry_after > 0 else 0
        super().__init__(
            status.HTTP_429_TOO_MANY_REQUESTS,
            code,
            message,
            extra={"retryAfter": seconds} if seconds else None,
        )
