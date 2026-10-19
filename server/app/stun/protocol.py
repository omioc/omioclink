"""STUN（RFC 8489）最小实现：只回答 Binding 请求的地址发现。

这里 **只有** 「你从公网看是什么地址」这一件事：
没有 TURN、没有中继、没有凭证体系，服务器不具备转发媒体包的能力。

报文格式（RFC 8489 §5）：

    0                   1                   2                   3
    0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |0 0|     STUN Message Type     |         Message Length        |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                         Magic Cookie                          |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
   |                     Transaction ID (96 bits)                  |
   +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
"""

from __future__ import annotations

import ipaddress
import struct
from typing import Final

__all__ = [
    "ATTR_XOR_MAPPED_ADDRESS",
    "BINDING_REQUEST",
    "BINDING_SUCCESS",
    "HEADER_LENGTH",
    "MAGIC_COOKIE",
    "TRANSACTION_ID_LENGTH",
    "build_binding_success",
    "is_binding_request",
    "transaction_id_of",
]

MAGIC_COOKIE: Final = 0x2112A442
BINDING_REQUEST: Final = 0x0001
BINDING_SUCCESS: Final = 0x0101
ATTR_XOR_MAPPED_ADDRESS: Final = 0x0020

HEADER_LENGTH: Final = 20
TRANSACTION_ID_LENGTH: Final = 12
_HEADER_STRUCT: Final = struct.Struct("!HHI")
_ATTR_HEADER_STRUCT: Final = struct.Struct("!HH")
#: 保留位(1B) + 地址族(1B) + X-Port(2B)
_ADDRESS_VALUE_STRUCT: Final = struct.Struct("!BBH")


def is_binding_request(data: bytes) -> bool:
    """校验是否为一个完整的 Binding Request。

    校验四件事：长度足够、类型是 Binding Request、magic cookie 正确、
    以及头部声明的属性长度不超过实际收到的字节数（防止截断报文被误当作合法请求）。
    """
    if len(data) < HEADER_LENGTH:
        return False
    # 显式 int()：struct 返回的是 Any，收窄成 int 以便静态检查与比较语义都明确
    header = _HEADER_STRUCT.unpack_from(data, 0)
    message_type = int(header[0])
    declared_length = int(header[1])
    cookie = int(header[2])
    if message_type != BINDING_REQUEST or cookie != MAGIC_COOKIE:
        return False
    return HEADER_LENGTH + declared_length <= len(data)


def transaction_id_of(data: bytes) -> bytes:
    """取出 96 位事务 ID，原样回显到响应里（客户端据此配对请求与响应）。"""
    return data[8 : 8 + TRANSACTION_ID_LENGTH]


def _encode_xor_mapped_address(address: str, port: int) -> bytes:
    """编码 XOR-MAPPED-ADDRESS 属性值。

    端口与 magic cookie 高 16 位异或；IPv4 地址与整个 magic cookie 异或。

    值布局（RFC 8489 §14.2）：1 字节保留位(0) + 1 字节地址族(0x01=IPv4)
    + 2 字节 X-Port + 4 字节 X-Address，共 8 字节，天然 4 字节对齐。
    注意保留位是 **1 字节**，不能写成 ``!HH``（那会占掉 2 字节，整个报文错位）。
    """
    packed = ipaddress.IPv4Address(address).packed
    cookie_bytes = struct.pack("!I", MAGIC_COOKIE)
    x_port = port ^ (MAGIC_COOKIE >> 16)
    x_address = bytes(byte ^ cookie_bytes[index] for index, byte in enumerate(packed))
    return _ADDRESS_VALUE_STRUCT.pack(0, 0x01, x_port) + x_address


def build_binding_success(transaction_id: bytes, address: str, port: int) -> bytes:
    """构造 Binding Success Response，把观测到的来源地址回给客户端。"""
    if len(transaction_id) != TRANSACTION_ID_LENGTH:
        raise ValueError("事务 ID 必须是 12 字节")
    value = _encode_xor_mapped_address(address, port)
    attribute = _ATTR_HEADER_STRUCT.pack(ATTR_XOR_MAPPED_ADDRESS, len(value)) + value
    header = (
        _HEADER_STRUCT.pack(BINDING_SUCCESS, len(attribute), MAGIC_COOKIE)
        + transaction_id
    )
    return header + attribute
