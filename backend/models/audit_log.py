"""Модель audit_log."""

from datetime import datetime
from typing import Optional

from sqlalchemy import DateTime, Integer, String, Text

from backend.db.session import Base
from sqlalchemy.orm import Mapped, mapped_column


class AuditLog(Base):
    """Журнал аудита действий."""

    __tablename__ = "audit_log"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    user_id: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    action: Mapped[str] = mapped_column(String(128), nullable=False)
    target: Mapped[Optional[str]] = mapped_column(String(255), nullable=True)
    details: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
    ip_address: Mapped[Optional[str]] = mapped_column(String(64), nullable=True)
