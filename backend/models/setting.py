"""Модель settings (key-value)."""

from sqlalchemy import String, Text
from sqlalchemy.orm import Mapped, mapped_column

from backend.db.session import Base


class Setting(Base):
    """Настройка системы (key-value)."""

    __tablename__ = "settings"

    key: Mapped[str] = mapped_column(String(255), primary_key=True)
    value: Mapped[str | None] = mapped_column(Text, nullable=True)
