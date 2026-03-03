"""Модель users и роли."""

from datetime import datetime
from typing import Optional

from sqlalchemy import DateTime, Enum, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from backend.db.session import Base
from backend.models.enums import RoleEnum


class User(Base):
    """Пользователь системы (admin/user)."""

    __tablename__ = "users"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    username: Mapped[str] = mapped_column(String(255), unique=True, nullable=False, index=True)
    password_hash: Mapped[str] = mapped_column(Text, nullable=False)
    role: Mapped[RoleEnum] = mapped_column(
        Enum(
            RoleEnum,
            name="roleenum",
            values_callable=lambda x: [e.value for e in x],
        ),
        default=RoleEnum.USER,
        nullable=False,
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
    last_login: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
