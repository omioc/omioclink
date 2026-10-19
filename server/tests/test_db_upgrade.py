"""老库升级测试。

``create_all`` 只创建缺失的表，**不会**给已存在的表加列。线上已经跑起来的实例
升级时，新增列必须靠 ``Database._apply_column_upgrades`` 补上——这条用例就是
用一个「旧版本的库」验证这条路，避免升级后直接 `no such column` 起不来。
"""

import sqlite3
from pathlib import Path

from sqlalchemy import text

from app.db.base import Database

_LEGACY_USERS_DDL = """
CREATE TABLE users (
    id INTEGER NOT NULL PRIMARY KEY AUTOINCREMENT,
    username VARCHAR(32) NOT NULL,
    display_name VARCHAR(48) NOT NULL,
    password_hash VARCHAR(128) NOT NULL,
    avatar VARCHAR(64),
    created_at DATETIME NOT NULL
)
"""

#: 旧版本（洛雪音源脚本）留下的表。ORM 模型已经删了，但线上老库里的表还在：
#: 启动时不能因为「metadata 里没有这张表」就报错，也不该做破坏性删除。
_LEGACY_MUSIC_SOURCES_DDL = """
CREATE TABLE music_sources (
    id VARCHAR(64) NOT NULL PRIMARY KEY,
    name VARCHAR(80) NOT NULL,
    version VARCHAR(32) NOT NULL,
    author VARCHAR(64) NOT NULL,
    homepage VARCHAR(255) NOT NULL,
    description VARCHAR(255) NOT NULL,
    script TEXT NOT NULL,
    sha256 VARCHAR(64) NOT NULL,
    enabled BOOLEAN NOT NULL,
    priority INTEGER NOT NULL,
    created_at DATETIME NOT NULL
)
"""


def _create_legacy_database(path: Path) -> None:
    """造一个没有 users.disabled 列的旧库，并放一行数据。"""
    connection = sqlite3.connect(path)
    try:
        connection.execute(_LEGACY_USERS_DDL)
        connection.execute(
            "INSERT INTO users (username, display_name, password_hash, created_at) "
            "VALUES ('alice', '小明', 'legacy-hash', '2026-01-01 00:00:00.000000')"
        )
        connection.commit()
    finally:
        connection.close()


def _columns(path: Path, table: str) -> set[str]:
    connection = sqlite3.connect(path)
    try:
        rows = connection.execute(f"PRAGMA table_info({table})").fetchall()
        return {row[1] for row in rows}
    finally:
        connection.close()


async def test_upgrade_adds_missing_column_and_keeps_rows(tmp_path: Path) -> None:
    db_path = tmp_path / "legacy.db"
    _create_legacy_database(db_path)
    assert "disabled" not in _columns(db_path, "users")

    database = Database(f"sqlite+aiosqlite:///{db_path}")
    try:
        await database.create_all()

        assert "disabled" in _columns(db_path, "users")
        async with database.session() as session:
            rows = (await session.execute(text("SELECT username, disabled FROM users"))).all()
        # 老数据保留，且新列默认值是 0（未禁用）
        assert rows == [("alice", 0)]
    finally:
        await database.dispose()


async def test_upgrade_is_idempotent(tmp_path: Path) -> None:
    """重复启动（多次 create_all）不能报错，也不能改动已升级的表。"""
    db_path = tmp_path / "legacy.db"
    _create_legacy_database(db_path)

    database = Database(f"sqlite+aiosqlite:///{db_path}")
    try:
        await database.create_all()
        await database.create_all()
        await database.create_all()
        assert "disabled" in _columns(db_path, "users")
    finally:
        await database.dispose()


async def test_fresh_database_gets_column_from_schema(tmp_path: Path) -> None:
    """全新库直接由 create_all 建表，也必须有这一列。"""
    db_path = tmp_path / "fresh.db"
    database = Database(f"sqlite+aiosqlite:///{db_path}")
    try:
        await database.create_all()
        assert "disabled" in _columns(db_path, "users")
        # 洛雪音源脚本的表已经不在模型里：全新库不该再建出来
        assert not _columns(db_path, "music_sources")
    finally:
        await database.dispose()


async def test_legacy_music_sources_table_does_not_block_startup(tmp_path: Path) -> None:
    """旧库残留的 music_sources 表不能影响启动（模型已删除，表原样留着）。"""
    db_path = tmp_path / "legacy.db"
    _create_legacy_database(db_path)
    connection = sqlite3.connect(db_path)
    try:
        connection.execute(_LEGACY_MUSIC_SOURCES_DDL)
        connection.execute(
            "INSERT INTO music_sources (id, name, version, author, homepage, description, "
            "script, sha256, enabled, priority, created_at) VALUES "
            "('abc', '旧音源', '1.0', '', '', '', 'function(){}', 'deadbeef', 1, 0, "
            "'2026-01-01 00:00:00.000000')"
        )
        connection.commit()
    finally:
        connection.close()

    database = Database(f"sqlite+aiosqlite:///{db_path}")
    try:
        await database.create_all()
        # 正常升级 users 表，同时不碰残留的音乐表（数据原地保留）
        assert "disabled" in _columns(db_path, "users")
        assert _columns(db_path, "music_sources")
        async with database.session() as session:
            rows = (await session.execute(text("SELECT id FROM music_sources"))).all()
        assert rows == [("abc",)]
    finally:
        await database.dispose()
