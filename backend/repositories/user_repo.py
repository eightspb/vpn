"""Минимальный репозиторий User."""

from typing import Optional

from sqlalchemy import select
from sqlalchemy.orm import Session

from backend.models import User


def get_by_username(session: Session, username: str) -> Optional[User]:
    """Найти пользователя по username."""
    return session.execute(select(User).where(User.username == username)).scalar_one_or_none()
