"""Модель peers_devices — связка VPN peer и подписки/пользователя."""

from datetime import date, datetime
from typing import Optional

from sqlalchemy import Date, DateTime, ForeignKey, Integer, String, Text

from backend.db.session import Base
from sqlalchemy.orm import Mapped, mapped_column


class PeerDevice(Base):
    """VPN peer/устройство, привязанное к пользователю/подписке."""

    __tablename__ = "peers_devices"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    ip: Mapped[str] = mapped_column(String(45), unique=True, nullable=False, index=True)
    type: Mapped[str] = mapped_column(String(64), default="phone", nullable=False)
    public_key: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    private_key: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
    config_file: Mapped[Optional[str]] = mapped_column(String(512), nullable=True)
    status: Mapped[str] = mapped_column(String(32), default="active", nullable=False)
    mode: Mapped[str] = mapped_column(String(16), default="full", nullable=False)
    group_name: Mapped[Optional[str]] = mapped_column(String(128), nullable=True)
    expiry_date: Mapped[Optional[date]] = mapped_column(Date, nullable=True)
    traffic_limit_mb: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    user_id: Mapped[Optional[int]] = mapped_column(ForeignKey("users.id"), nullable=True)
    subscription_id: Mapped[Optional[int]] = mapped_column(
        ForeignKey("subscriptions.id"), nullable=True
    )
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)
    config_version: Mapped[int] = mapped_column(Integer, default=1, nullable=False)
    config_download_count: Mapped[int] = mapped_column(Integer, default=0, nullable=False)
    last_config_downloaded_at: Mapped[Optional[datetime]] = mapped_column(DateTime(timezone=True), nullable=True)
    last_downloaded_config_version: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)
    source_id: Mapped[Optional[str]] = mapped_column(
        String(128), unique=True, nullable=True, index=True
    )
    # source_id = уникальный ID из источника миграции для идемпотентности (e.g. "sqlite:5" или "json:10.9.0.5")
