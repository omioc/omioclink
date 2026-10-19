"""验证 `python -m app.stun` 这个**部署入口**真的能起来并应答。

compose 里 stun 服务的启动命令就是它。之前只单测了协议编解码与 `StunProtocol`，
入口本身（argparse / asyncio.run / 信号处理 / 真实 UDP 绑定）没被覆盖过——
一旦它有问题，表现就是「服务器上没有 UDP 端口在监听」。
"""

import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

import pytest

from app.stun.protocol import MAGIC_COOKIE
from tests.test_stun import decode_xor_mapped_address

SERVER_ROOT = Path(__file__).resolve().parent.parent


def _free_udp_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def _binding_request(transaction_id: bytes) -> bytes:
    return struct.pack("!HHI", 0x0001, 0, MAGIC_COOKIE) + transaction_id


def test_module_entrypoint_binds_and_answers_udp() -> None:
    port = _free_udp_port()
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "app.stun",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
        ],
        cwd=SERVER_ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    transaction_id = bytes(range(12))
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as client:
            client.settimeout(0.5)
            # 先显式绑定再取端口（未绑定时 getsockname 返回 0），
            # 且必须在 with 块内取——出块后套接字已关闭
            client.bind(("127.0.0.1", 0))
            client_port = int(client.getsockname()[1])
            deadline = time.monotonic() + 20
            response: bytes | None = None
            while response is None:
                if process.poll() is not None:
                    output = process.stdout.read() if process.stdout else ""
                    pytest.fail(f"STUN 入口进程提前退出（code={process.returncode}）：\n{output}")
                client.sendto(_binding_request(transaction_id), ("127.0.0.1", port))
                try:
                    response, _ = client.recvfrom(2048)
                except OSError:
                    # 服务还没起来时：Linux 上是超时（TimeoutError 是 OSError 子类），
                    # Windows 上还会在 ICMP 端口不可达回来后抛 ConnectionResetError
                    # (WinError 10054)。两种都只是「再试一次」。
                    if time.monotonic() > deadline:
                        pytest.fail("STUN 入口 20 秒内没有应答（端口未监听？）")

        assert response[8:20] == transaction_id, "事务 ID 必须原样回显"
        assert decode_xor_mapped_address(response) == ("127.0.0.1", client_port)
    finally:
        # 用 communicate() 而不是 wait()：它会顺手关掉 stdout 管道，
        # 否则未关闭的 FileIO 被 GC 时会变成 PytestUnraisableExceptionWarning
        process.terminate()
        try:
            process.communicate(timeout=10)
        except subprocess.TimeoutExpired:  # pragma: no cover - 兜底
            process.kill()
            process.communicate(timeout=10)


def test_module_entrypoint_reports_bad_port() -> None:
    """参数不合法要以非零码退出，而不是静默不监听。"""
    completed = subprocess.run(
        [sys.executable, "-m", "app.stun", "--port", "70000"],
        cwd=SERVER_ROOT,
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )
    output = completed.stdout + completed.stderr
    assert completed.returncode != 0
    assert "70000" in output or "port" in output.lower()
