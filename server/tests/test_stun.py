"""STUN 报文与会话测试。

验证方式上刻意避免「自己验自己」：测试里另写一份**独立的解码器**，
并且端到端用例真的开一个 UDP socket 打一发请求。
"""

from __future__ import annotations

import asyncio
import ipaddress
import socket
import struct

import pytest

from app.stun.protocol import (
    BINDING_SUCCESS,
    MAGIC_COOKIE,
    build_binding_success,
    is_binding_request,
    transaction_id_of,
)
from app.stun.server import StunProtocol

_ATTR_XOR_MAPPED_ADDRESS = 0x0020


# --------------------------------------------------------------------------- #
# 测试侧的独立实现（不引用被测模块的任何逻辑）
# --------------------------------------------------------------------------- #
def build_request(transaction_id: bytes) -> bytes:
    return struct.pack("!HHI", 0x0001, 0, 0x2112A442) + transaction_id


def decode_xor_mapped_address(message: bytes) -> tuple[str, int]:
    """把响应里的 XOR-MAPPED-ADDRESS 还原成 (ip, port)。"""
    message_type, length, cookie = struct.unpack_from("!HHI", message, 0)
    assert message_type == BINDING_SUCCESS, f"不是 Binding Success: 0x{message_type:04x}"
    assert cookie == MAGIC_COOKIE
    offset = 20
    end = 20 + length
    while offset + 4 <= end:
        attribute_type, attribute_length = struct.unpack_from("!HH", message, offset)
        value = message[offset + 4 : offset + 4 + attribute_length]
        if attribute_type == _ATTR_XOR_MAPPED_ADDRESS:
            assert value[0] == 0, "保留位必须为 0"
            assert value[1] == 0x01, "地址族必须是 IPv4"
            port = struct.unpack_from("!H", value, 2)[0] ^ (MAGIC_COOKIE >> 16)
            cookie_bytes = struct.pack("!I", MAGIC_COOKIE)
            raw = bytes(byte ^ cookie_bytes[index] for index, byte in enumerate(value[4:8]))
            return str(ipaddress.IPv4Address(raw)), port
        offset += 4 + attribute_length + ((4 - attribute_length % 4) % 4)
    raise AssertionError("响应里没有 XOR-MAPPED-ADDRESS")


TRANSACTION_ID = bytes(range(12))


# --------------------------------------------------------------------------- #
# 报文校验
# --------------------------------------------------------------------------- #
def test_accepts_well_formed_binding_request() -> None:
    assert is_binding_request(build_request(TRANSACTION_ID)) is True
    # 请求带属性（声明长度 8）也应当接受
    with_attributes = struct.pack("!HHI", 0x0001, 8, MAGIC_COOKIE) + TRANSACTION_ID + b"\x00" * 8
    assert is_binding_request(with_attributes) is True


@pytest.mark.parametrize(
    "payload",
    [
        b"",  # 空
        b"\x00" * 19,  # 不足 20 字节头
        struct.pack("!HHI", 0x0101, 0, MAGIC_COOKIE) + TRANSACTION_ID,  # 不是请求
        struct.pack("!HHI", 0x0001, 0, 0xDEADBEEF) + TRANSACTION_ID,  # magic cookie 不对
        struct.pack("!HHI", 0x0001, 64, MAGIC_COOKIE) + TRANSACTION_ID,  # 声明长度超过实际
        b"garbage-not-stun",  # 垃圾数据
    ],
)
def test_rejects_malformed_datagrams(payload: bytes) -> None:
    assert is_binding_request(payload) is False


def test_transaction_id_is_extracted_verbatim() -> None:
    assert transaction_id_of(build_request(TRANSACTION_ID)) == TRANSACTION_ID


# --------------------------------------------------------------------------- #
# 响应构造
# --------------------------------------------------------------------------- #
def test_build_binding_success_encodes_observed_address() -> None:
    response = build_binding_success(TRANSACTION_ID, "203.0.113.7", 54321)

    message_type, length, cookie = struct.unpack_from("!HHI", response, 0)
    assert message_type == BINDING_SUCCESS
    assert cookie == MAGIC_COOKIE
    assert response[8:20] == TRANSACTION_ID, "事务 ID 必须原样回显"
    assert length == len(response) - 20 == 12, "一个属性：4 字节头 + 8 字节值"
    assert len(response) == 32

    attribute_type, attribute_length = struct.unpack_from("!HH", response, 20)
    assert attribute_type == _ATTR_XOR_MAPPED_ADDRESS
    assert attribute_length == 8

    assert decode_xor_mapped_address(response) == ("203.0.113.7", 54321)


def test_xor_is_actually_applied() -> None:
    """防止有人把 XOR 简化掉：属性值的地址部分不能等于明文地址。"""
    response = build_binding_success(TRANSACTION_ID, "203.0.113.7", 54321)
    value = response[24:32]
    plain = ipaddress.IPv4Address("203.0.113.7").packed
    assert value[4:8] != plain
    cookie_bytes = struct.pack("!I", MAGIC_COOKIE)
    assert value[4:8] == bytes(b ^ cookie_bytes[i] for i, b in enumerate(plain))
    # 端口同样做了 XOR
    assert struct.unpack_from("!H", value, 2)[0] == 54321 ^ (MAGIC_COOKIE >> 16)


def test_build_rejects_wrong_transaction_id_length() -> None:
    with pytest.raises(ValueError):
        build_binding_success(b"too-short", "10.0.0.1", 1)
    with pytest.raises(ValueError):
        build_binding_success(b"\x00" * 16, "10.0.0.1", 1)


# --------------------------------------------------------------------------- #
# 端到端（真实 UDP socket）
# --------------------------------------------------------------------------- #
async def test_answers_binding_request_over_udp() -> None:
    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_datagram_endpoint(
        StunProtocol, local_addr=("127.0.0.1", 0)
    )
    assert isinstance(protocol, StunProtocol)
    try:
        server_port = transport.get_extra_info("sockname")[1]
        client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        client.setblocking(False)
        try:
            client.bind(("127.0.0.1", 0))
            client_port = client.getsockname()[1]
            client.sendto(build_request(TRANSACTION_ID), ("127.0.0.1", server_port))

            data, _ = await asyncio.wait_for(loop.sock_recvfrom(client, 2048), timeout=3)
            assert decode_xor_mapped_address(data) == ("127.0.0.1", client_port)
            assert protocol.answered == 1
            assert protocol.ignored == 0
        finally:
            client.close()
    finally:
        transport.close()


async def test_non_stun_datagrams_get_no_reply() -> None:
    """先发垃圾再发合法请求：收到的第一条必须是合法请求的响应。"""
    loop = asyncio.get_running_loop()
    transport, protocol = await loop.create_datagram_endpoint(
        StunProtocol, local_addr=("127.0.0.1", 0)
    )
    try:
        server_port = transport.get_extra_info("sockname")[1]
        client = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        client.setblocking(False)
        try:
            client.bind(("127.0.0.1", 0))
            client.sendto(b"definitely-not-a-stun-packet", ("127.0.0.1", server_port))
            await asyncio.sleep(0.05)
            client.sendto(build_request(TRANSACTION_ID), ("127.0.0.1", server_port))

            data, _ = await asyncio.wait_for(loop.sock_recvfrom(client, 2048), timeout=3)
            assert data[8:20] == TRANSACTION_ID
            assert protocol.ignored == 1
            assert protocol.answered == 1
        finally:
            client.close()
    finally:
        transport.close()


async def test_serve_binds_and_stops(monkeypatch: pytest.MonkeyPatch) -> None:
    """serve() 能被取消：起在临时端口上，取消后不留悬挂任务。"""
    task = asyncio.create_task(_serve_on_ephemeral_port())
    await asyncio.sleep(0.05)
    task.cancel()
    with pytest.raises(asyncio.CancelledError):
        await task


async def _serve_on_ephemeral_port() -> None:
    from app.stun.server import serve

    await serve("127.0.0.1", 0)
