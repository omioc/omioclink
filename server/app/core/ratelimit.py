"""登录限流。

三件事，都是**进程内内存**实现：

* 管理台密码：同一来源连续错 5 次 → 锁 5 分钟（``FailureLockout``）；
* 客户端账号：同一用户名失败计数 + 指数退避，前 3 次不惩罚，
  之后 2s → 4s → … 封顶 60s（``FailureBackoff``）；
* 同一来源的登录请求频率：5 分钟内最多 10 次，成功失败都算（``SlidingWindowLimiter``）。

为什么不上 Redis / 数据库：这是单进程单容器的自部署服务，登录本身是低频操作。
内存计数的代价是「重启清零」和「多副本不共享」，对这里的威胁模型（在线猜密码）
都可以接受；为它引入外部依赖反而多一个故障点。

为什么要按来源 IP 限流：账号级退避挡不住「拿一堆用户名挨个试」的扫号，而来源级
窗口能。取 IP 的规则见 [client_ip]——只有对端本身是内网/回环（也就是前面挂了反代）
时才信任 ``X-Forwarded-For``，公网直连的请求伪造这个头不会绕过限流。
"""

from __future__ import annotations

import ipaddress
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Final

from fastapi import Request

__all__ = [
    "FailureBackoff",
    "FailureLockout",
    "LoginLimits",
    "SlidingWindowLimiter",
    "client_ip",
]

#: 记账字典的上限：超过就顺手清掉已经过期的键。
#: 公网上的扫号会带来大量一次性 key，不清就是一条慢速内存泄漏。
_MAX_KEYS: Final = 4096


def client_ip(request: Request) -> str:
    """这次请求的来源 IP。

    直连部署（compose 直接映射端口）时对端地址就是真实 IP；挂了 TLS 反代时对端是
    内网/回环地址，真实 IP 只在 ``X-Forwarded-For`` 的第一段里。所以只在「对端本身
    是内网/回环」时才采纳这个头——公网直连的请求即便伪造它也不会被信任。
    """
    peer = request.client.host if request.client is not None else ""
    if _is_local(peer):
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            first = forwarded.split(",")[0].strip()
            if first:
                return first
    return peer or "unknown"


def _is_local(host: str) -> bool:
    try:
        address = ipaddress.ip_address(host)
    except ValueError:
        # TestClient 之类的非 IP 对端名：按直连处理，不去读转发头
        return False
    return address.is_private or address.is_loopback


class SlidingWindowLimiter:
    """滑动窗口计数：``window_seconds`` 秒内最多 ``limit`` 次。"""

    def __init__(
        self,
        *,
        limit: int,
        window_seconds: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._limit = limit
        self._window = window_seconds
        self._clock = clock
        self._hits: dict[str, deque[float]] = {}

    def retry_after(self, key: str) -> float:
        """还要等多少秒才能再试；0 表示现在就可以。不记账。"""
        bucket = self._hits.get(key)
        if bucket is None:
            return 0.0
        now = self._clock()
        self._trim(bucket, now)
        if not bucket:
            self._hits.pop(key, None)
            return 0.0
        if len(bucket) < self._limit:
            return 0.0
        return max(0.0, bucket[0] + self._window - now)

    def hit(self, key: str) -> float:
        """记一次请求。返回 >0 表示这次应当拒绝，并给出还要等的秒数。"""
        wait = self.retry_after(key)
        if wait > 0:
            return wait
        self._hits.setdefault(key, deque()).append(self._clock())
        self._maybe_prune()
        return 0.0

    def _trim(self, bucket: deque[float], now: float) -> None:
        cutoff = now - self._window
        while bucket and bucket[0] <= cutoff:
            bucket.popleft()

    def _maybe_prune(self) -> None:
        if len(self._hits) <= _MAX_KEYS:
            return
        now = self._clock()
        for key in [k for k, bucket in self._hits.items() if not bucket]:
            self._hits.pop(key, None)
        stale = [
            key
            for key, bucket in self._hits.items()
            if bucket and bucket[-1] + self._window <= now
        ]
        for key in stale:
            self._hits.pop(key, None)


class FailureLockout:
    """连续失败 ``threshold`` 次就锁住 ``lock_seconds`` 秒。"""

    def __init__(
        self,
        *,
        threshold: int,
        lock_seconds: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._threshold = threshold
        self._lock_seconds = lock_seconds
        self._clock = clock
        self._failures: dict[str, int] = {}
        self._locked_until: dict[str, float] = {}

    def locked_for(self, key: str) -> float:
        """还剩多少秒解锁；0 表示没被锁。"""
        until = self._locked_until.get(key)
        if until is None:
            return 0.0
        remaining = until - self._clock()
        if remaining <= 0:
            self._locked_until.pop(key, None)
            return 0.0
        return remaining

    def record_failure(self, key: str) -> float:
        """记一次失败，返回锁定剩余秒数（0 表示这次还没到阈值）。"""
        count = self._failures.get(key, 0) + 1
        self._failures[key] = count
        if count < self._threshold:
            return 0.0
        self._failures.pop(key, None)
        self._locked_until[key] = self._clock() + self._lock_seconds
        self._maybe_prune()
        return self._lock_seconds

    def clear(self, key: str) -> None:
        self._failures.pop(key, None)
        self._locked_until.pop(key, None)

    def _maybe_prune(self) -> None:
        if len(self._locked_until) <= _MAX_KEYS:
            return
        now = self._clock()
        for key in [k for k, until in self._locked_until.items() if until <= now]:
            self._locked_until.pop(key, None)
            self._failures.pop(key, None)


class FailureBackoff:
    """失败计数 + 指数退避（同一个账号反复输错密码时用）。

    前 ``free_failures`` 次不惩罚：正常用户手滑两次不该被卡住；到第 4 次才开始
    要求等待 ``base * 2^(n-free-1)`` 秒，封顶 ``cap_seconds``。
    ``reset_after_seconds`` 内没有新的失败就把计数清零，不会「错三次记一辈子」。
    """

    def __init__(
        self,
        *,
        free_failures: int,
        base_seconds: float,
        cap_seconds: float,
        reset_after_seconds: float,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._free = free_failures
        self._base = base_seconds
        self._cap = cap_seconds
        self._reset_after = reset_after_seconds
        self._clock = clock
        #: key → (失败次数, 最后一次失败时刻, 允许再试的时刻)
        self._state: dict[str, tuple[int, float, float]] = {}

    def retry_after(self, key: str) -> float:
        """还要等多少秒；0 表示可以试。"""
        state = self._state.get(key)
        if state is None:
            return 0.0
        _failures, last, allowed_at = state
        now = self._clock()
        if now - last > self._reset_after:
            self._state.pop(key, None)
            return 0.0
        return max(0.0, allowed_at - now)

    def record_failure(self, key: str) -> float:
        """记一次失败，返回这次之后需要等待的秒数（0 表示不用等）。"""
        now = self._clock()
        previous = self._state.get(key)
        failures = 1
        if previous is not None and now - previous[1] <= self._reset_after:
            failures = previous[0] + 1
        delay = 0.0
        if failures > self._free:
            delay = min(self._base * (2 ** (failures - self._free - 1)), self._cap)
        self._state[key] = (failures, now, now + delay)
        self._maybe_prune()
        return delay

    def clear(self, key: str) -> None:
        self._state.pop(key, None)

    def _maybe_prune(self) -> None:
        if len(self._state) <= _MAX_KEYS:
            return
        now = self._clock()
        for key in [k for k, s in self._state.items() if now - s[1] > self._reset_after]:
            self._state.pop(key, None)


@dataclass
class LoginLimits:
    """一次发版内的全部登录限流阈值（集中放这里，别散在各接口里）。"""

    #: 同一来源 5 分钟内最多 10 次登录请求（含成功）
    login_ip: SlidingWindowLimiter = field(
        default_factory=lambda: SlidingWindowLimiter(limit=10, window_seconds=300)
    )
    #: 同一用户名：前 3 次失败免费，之后指数退避，15 分钟无新失败即清零
    account: FailureBackoff = field(
        default_factory=lambda: FailureBackoff(
            free_failures=3,
            base_seconds=2,
            cap_seconds=60,
            reset_after_seconds=900,
        )
    )
    #: 管理台：同一来源错 5 次锁 5 分钟
    admin: FailureLockout = field(
        default_factory=lambda: FailureLockout(threshold=5, lock_seconds=300)
    )

    @classmethod
    def with_clock(cls, clock: Callable[[], float]) -> LoginLimits:
        """测试用：换掉时钟，不必真的等 5 分钟。"""
        return cls(
            login_ip=SlidingWindowLimiter(limit=10, window_seconds=300, clock=clock),
            account=FailureBackoff(
                free_failures=3,
                base_seconds=2,
                cap_seconds=60,
                reset_after_seconds=900,
                clock=clock,
            ),
            admin=FailureLockout(threshold=5, lock_seconds=300, clock=clock),
        )
