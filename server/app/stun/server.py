"""最小 STUN 服务：只回答 Binding 请求，不做任何中继。

定位（见 docs/技术调研报告 §6.1）：STUN 与信令同级，属于「连接发现」而非中继——
它只回一句「你从公网看是什么地址」，流量可忽略（每连接几十 KB）。

为什么不用 coturn：本项目只需要标准 STUN 地址发现，引入一个带 TURN/凭证/数据库
的完整组件反而扩大了服务器攻击面。这里的实现**结构上不可能转发媒体**。

前提：服务器必须有真实公网 IPv4（本项目的既定约束）。响应回显的是内核观测到的
来源地址，服务器若处于 NAT 之后，回显的会是内网地址，此时需要 external-ip 映射——
不在本项目范围内。

用法：
    python -m app.stun --host 0.0.0.0 --port 3478
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import logging
import signal
from typing import Any, cast

from app.stun.protocol import build_binding_success, is_binding_request, transaction_id_of

logger = logging.getLogger(__name__)

__all__ = ["DEFAULT_HOST", "DEFAULT_PORT", "StunProtocol", "main", "serve"]

DEFAULT_HOST = "0.0.0.0"
DEFAULT_PORT = 3478


class StunProtocol(asyncio.DatagramProtocol):
    """每个数据报只做一件事：是 Binding 请求就把对端地址回过去，否则丢弃。"""

    def __init__(self) -> None:
        self.transport: asyncio.DatagramTransport | None = None
        self.answered = 0
        self.ignored = 0

    def connection_made(self, transport: asyncio.BaseTransport) -> None:
        # create_datagram_endpoint 传进来的必然是 datagram transport；
        # 用 cast 而不是 isinstance，避免运行时判断失败导致服务静默不响应
        self.transport = cast("asyncio.DatagramTransport", transport)

    def datagram_received(self, data: bytes, addr: tuple[Any, ...]) -> None:
        if self.transport is None:
            return
        if not is_binding_request(data):
            self.ignored += 1
            return
        host = str(addr[0])
        port = int(addr[1])
        try:
            response = build_binding_success(transaction_id_of(data), host, port)
        except ValueError:
            self.ignored += 1
            return
        self.transport.sendto(response, addr)
        self.answered += 1


async def serve(host: str = DEFAULT_HOST, port: int = DEFAULT_PORT) -> None:
    """监听 UDP 并持续应答，直到被取消。"""
    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_datagram_endpoint(
        StunProtocol, local_addr=(host, port)
    )
    assert isinstance(protocol, StunProtocol)
    logger.info("STUN 监听 %s:%s（仅地址发现，无中继）", host, port)

    stop = asyncio.Event()
    for signal_name in ("SIGINT", "SIGTERM"):
        number = getattr(signal, signal_name, None)
        if number is None:  # pragma: no cover - Windows 无 SIGTERM 语义差异
            continue
        # Windows 的事件循环不支持 add_signal_handler
        with contextlib.suppress(NotImplementedError):
            loop.add_signal_handler(number, stop.set)

    try:
        await stop.wait()
    finally:
        transport.close()
        logger.info("STUN 退出：应答 %s 个、忽略 %s 个", protocol.answered, protocol.ignored)


def main() -> None:
    parser = argparse.ArgumentParser(description="OmiocLink 最小 STUN 服务（仅地址发现）")
    parser.add_argument("--host", default=DEFAULT_HOST, help=f"监听地址，默认 {DEFAULT_HOST}")
    parser.add_argument(
        "--port", type=int, default=DEFAULT_PORT, help=f"监听端口，默认 {DEFAULT_PORT}"
    )
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        asyncio.run(serve(args.host, args.port))
    except KeyboardInterrupt:  # pragma: no cover - Ctrl-C
        logger.info("收到中断信号，退出")
