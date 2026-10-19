"""口令哈希与 JWT 单元测试。"""

from datetime import UTC, datetime, timedelta

import pytest

from app.core.security import (
    BCRYPT_MAX_BYTES,
    PasswordTooLongError,
    create_access_token,
    decode_access_token,
    hash_password,
    password_fingerprint,
    verify_password,
)

SECRET = "unit-test-secret-key-32-bytes-min!!"
ALGORITHM = "HS256"


def test_hash_password_is_salted_and_verifiable() -> None:
    first = hash_password("correct horse battery staple")
    second = hash_password("correct horse battery staple")
    assert first != second  # 加盐
    assert verify_password("correct horse battery staple", first)
    assert not verify_password("wrong password", first)


def test_verify_password_handles_missing_hash() -> None:
    assert not verify_password("whatever", None)
    assert not verify_password("whatever", "not-a-bcrypt-hash")


def test_hash_password_rejects_overlong_secret() -> None:
    with pytest.raises(PasswordTooLongError):
        hash_password("あ" * (BCRYPT_MAX_BYTES // 3 + 1))
    assert not verify_password("あ" * (BCRYPT_MAX_BYTES // 3 + 1), hash_password("ok-pass"))


def test_access_token_roundtrip() -> None:
    token = create_access_token(
        user_id=42,
        username="alice",
        secret=SECRET,
        algorithm=ALGORITHM,
        ttl_seconds=600,
        password_fingerprint="fingerprint-a",
    )
    payload = decode_access_token(token, secret=SECRET, algorithm=ALGORITHM)
    assert payload is not None
    assert payload["sub"] == "42"
    assert payload["username"] == "alice"
    assert payload["pwf"] == "fingerprint-a"


def test_password_fingerprint_tracks_the_hash_only() -> None:
    """指纹对「同一密钥 + 同一哈希」稳定，哈希一变（=改了密码）就变。"""
    first = hash_password("first-password")
    second = hash_password("second-password")

    assert password_fingerprint(secret=SECRET, password_hash=first) == (
        password_fingerprint(secret=SECRET, password_hash=first)
    )
    assert password_fingerprint(secret=SECRET, password_hash=first) != (
        password_fingerprint(secret=SECRET, password_hash=second)
    )
    # 换密钥也算不同的指纹；哈希为 None 时不能崩
    assert password_fingerprint(secret="other-key-32-bytes-long!!!!!!!!", password_hash=first) != (
        password_fingerprint(secret=SECRET, password_hash=first)
    )
    assert password_fingerprint(secret=SECRET, password_hash=None) != ""
    # 不能把 bcrypt 哈希原样塞进令牌里
    assert first not in password_fingerprint(secret=SECRET, password_hash=first)


def test_access_token_rejects_bad_signature_and_expiry() -> None:
    token = create_access_token(
        user_id=1,
        username="bob",
        secret=SECRET,
        algorithm=ALGORITHM,
        ttl_seconds=600,
        password_fingerprint="fingerprint-a",
    )
    assert (
        decode_access_token(token, secret="another-secret-key-32-bytes-ok!!", algorithm=ALGORITHM)
        is None
    )

    expired = create_access_token(
        user_id=1,
        username="bob",
        secret=SECRET,
        algorithm=ALGORITHM,
        ttl_seconds=60,
        password_fingerprint="fingerprint-a",
        now=datetime.now(UTC) - timedelta(hours=2),
    )
    assert decode_access_token(expired, secret=SECRET, algorithm=ALGORITHM) is None
    assert decode_access_token("garbage", secret=SECRET, algorithm=ALGORITHM) is None
