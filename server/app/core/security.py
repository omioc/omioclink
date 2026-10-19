"""账号口令与 JWT 工具。"""

import hashlib
import hmac
from datetime import UTC, datetime, timedelta
from typing import Any, Final

import bcrypt
import jwt

__all__ = [
    "BCRYPT_MAX_BYTES",
    "PasswordTooLongError",
    "create_access_token",
    "decode_access_token",
    "hash_password",
    "password_fingerprint",
    "verify_password",
]

#: bcrypt 算法本身只处理前 72 字节，超长口令直接拒绝而不是静默截断。
BCRYPT_MAX_BYTES: Final = 72


class PasswordTooLongError(ValueError):
    """口令的 UTF-8 字节长度超过 bcrypt 上限。"""


def hash_password(password: str) -> str:
    raw = password.encode("utf-8")
    if len(raw) > BCRYPT_MAX_BYTES:
        raise PasswordTooLongError
    return bcrypt.hashpw(raw, bcrypt.gensalt()).decode("ascii")


def verify_password(password: str, password_hash: str | None) -> bool:
    if not password_hash:
        return False
    raw = password.encode("utf-8")
    if len(raw) > BCRYPT_MAX_BYTES:
        return False
    try:
        return bcrypt.checkpw(raw, password_hash.encode("ascii"))
    except ValueError:
        return False


def password_fingerprint(*, secret: str, password_hash: str | None) -> str:
    """当前口令的指纹，用于让「改密码」立刻作废此前签发的所有令牌。

    取自 HMAC-SHA256 的前 16 个十六进制字符：对同一密钥+哈希稳定，但**不泄露**
    bcrypt 哈希本身（哈希是机密，泄露等于把离线爆破的门槛降一个量级）。
    把指纹放进 JWT 的 ``pwf`` 声明，校验时与库里当前哈希重新算一遍比对即可——
    不需要为此加数据库字段，也不需要在内存里维护「已吊销令牌」集合。
    """
    digest = hmac.new(
        secret.encode("utf-8"),
        (password_hash or "").encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    return digest[:16]


def create_access_token(
    *,
    user_id: int,
    username: str,
    secret: str,
    algorithm: str,
    ttl_seconds: int,
    password_fingerprint: str,
    now: datetime | None = None,
) -> str:
    issued_at = now or datetime.now(UTC)
    payload: dict[str, Any] = {
        "sub": str(user_id),
        "username": username,
        # 口令版本：改密码后这个值会变，旧令牌随即失效
        "pwf": password_fingerprint,
        "iat": int(issued_at.timestamp()),
        "exp": int((issued_at + timedelta(seconds=ttl_seconds)).timestamp()),
    }
    return jwt.encode(payload, secret, algorithm=algorithm)


def decode_access_token(token: str, *, secret: str, algorithm: str) -> dict[str, Any] | None:
    """解码并校验 JWT，失败（过期/签名错误/格式错误）返回 None。"""
    try:
        payload = jwt.decode(token, secret, algorithms=[algorithm])
    except jwt.PyJWTError:
        return None
    if not isinstance(payload, dict) or "sub" not in payload:
        return None
    return payload
