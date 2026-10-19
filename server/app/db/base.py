"""数据库引擎与会话工厂。"""

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager
from typing import Final

from sqlalchemy import event
from sqlalchemy.engine import Connection
from sqlalchemy.ext.asyncio import (
    AsyncEngine,
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase

logger = logging.getLogger(__name__)

__all__ = ["Base", "Database"]

#: 增量升级清单：(表, 列, SQLite 列定义)。只在列缺失时执行 ALTER TABLE。
_COLUMN_UPGRADES: Final[tuple[tuple[str, str, str], ...]] = (
    ("users", "disabled", "BOOLEAN NOT NULL DEFAULT 0"),
)


class Base(DeclarativeBase):
    """所有 ORM 模型的基类。"""


class Database:
    """轻量封装：引擎 + 建表 + 会话工厂。

    SQLite 下额外打开外键约束（默认关闭），保证 ``ondelete`` 生效。
    """

    def __init__(self, url: str) -> None:
        self.url = url
        # 用默认连接池（而不是 NullPool）：aiosqlite 每建一条连接都会起一个线程，
        # 而关闭连接是一次 await —— NullPool 下每次请求都要新建+关闭连接，
        # 只要有一次关闭被取消（请求任务被取消、停机被打断）就会永久泄漏一条连接，
        # 并让事件循环里残留卡在 _terminate_graceful_close 的任务。
        # 走连接池后，连接的建立与关闭都收敛到引擎生命周期上，
        # 关闭只发生在 dispose()（已用 shield 保护，见 app.main）。
        # 引擎是「每个应用一个」，所以不存在跨事件循环复用连接的问题。
        self.engine: AsyncEngine = create_async_engine(url, future=True)
        self.session_factory: async_sessionmaker[AsyncSession] = async_sessionmaker(
            self.engine, expire_on_commit=False
        )
        if url.startswith("sqlite"):
            self._enable_sqlite_foreign_keys(self.engine)

    @staticmethod
    def _enable_sqlite_foreign_keys(engine: AsyncEngine) -> None:
        @event.listens_for(engine.sync_engine, "connect")
        def _set_pragma(dbapi_connection: object, _record: object) -> None:  # pragma: no cover
            cursor = dbapi_connection.cursor()  # type: ignore[attr-defined]
            cursor.execute("PRAGMA foreign_keys=ON")
            cursor.close()

    async def create_all(self) -> None:
        # 确保所有模型都已注册到 metadata
        from app.db import models  # noqa: F401

        async with self.engine.begin() as conn:
            await conn.run_sync(Base.metadata.create_all)
            if self._is_sqlite:
                await conn.run_sync(self._apply_column_upgrades)

    @staticmethod
    def _apply_column_upgrades(connection: Connection) -> None:
        """给已存在的旧库补上新增的列。

        ``create_all`` 只创建缺失的**表**，绝不会修改已存在的表结构，所以升级部署时
        新加的列必须显式补。这里用最朴素的方式（PRAGMA 看列是否存在 → ALTER TABLE），
        足够支撑当前的单表小改动；等表结构复杂起来再引入 alembic 之类的正式迁移工具。
        """
        for table, column, ddl in _COLUMN_UPGRADES:
            rows = connection.exec_driver_sql(f"PRAGMA table_info({table})").fetchall()
            if not rows:
                continue  # 表还不存在时 create_all 已经建全，这里不用管
            if column in {row[1] for row in rows}:
                continue
            connection.exec_driver_sql(f"ALTER TABLE {table} ADD COLUMN {column} {ddl}")
            logger.info("数据库升级：%s 表补上 %s 列", table, column)

    @property
    def _is_sqlite(self) -> bool:
        return self.url.startswith("sqlite")

    async def drop_all(self) -> None:
        from app.db import models  # noqa: F401

        async with self.engine.begin() as conn:
            await conn.run_sync(Base.metadata.drop_all)

    async def dispose(self) -> None:
        await self.engine.dispose()

    @asynccontextmanager
    async def session(self) -> AsyncIterator[AsyncSession]:
        async with self.session_factory() as session:
            yield session
