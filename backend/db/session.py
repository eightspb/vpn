"""Database session и engine для Postgres."""

from contextlib import contextmanager
from typing import Generator

from sqlalchemy import create_engine
from sqlalchemy.orm import Session, declarative_base, sessionmaker

from backend.core.config import get_settings

Base = declarative_base()
engine = None
SessionLocal = None


def _ensure_engine():
    global engine, SessionLocal
    if engine is not None:
        return
    settings = get_settings()
    if not settings.DATABASE_URL:
        raise RuntimeError("DATABASE_URL required for DB operations")
    engine = create_engine(
        settings.DATABASE_URL,
        pool_pre_ping=True,
        pool_size=5,
        max_overflow=10,
        pool_timeout=30,
        pool_recycle=1800,
        echo=False,
    )
    SessionLocal = sessionmaker(autocommit=False, autoflush=False, bind=engine)


def get_engine():
    _ensure_engine()
    return engine


def get_session_factory():
    """Возвращает sessionmaker (для миграций с ручным commit)."""
    _ensure_engine()
    return SessionLocal


@contextmanager
def get_session() -> Generator[Session, None, None]:
    """Context manager для получения сессии."""
    _ensure_engine()
    session = SessionLocal()
    try:
        yield session
        session.commit()
    except Exception:
        session.rollback()
        raise
    finally:
        session.close()
