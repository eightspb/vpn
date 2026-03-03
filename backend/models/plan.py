"""Модели тарифов (plans, plan_offers)."""

from datetime import datetime
from decimal import Decimal
from typing import Optional

from sqlalchemy import DateTime, Enum, ForeignKey, Integer, Numeric, String
from sqlalchemy.orm import Mapped, mapped_column, relationship

from backend.db.session import Base
from backend.models.enums import PlanKind


class Plan(Base):
    """Тарифный план."""

    __tablename__ = "plans"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    name: Mapped[str] = mapped_column(String(255), nullable=False)
    kind: Mapped[PlanKind] = mapped_column(
        Enum(
            PlanKind,
            name="plankind",
            values_callable=lambda x: [e.value for e in x],
        ),
        nullable=False,
    )
    description: Mapped[Optional[str]] = mapped_column(String(1024), nullable=True)
    traffic_limit_mb: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)  # для TRAFFIC
    device_limit: Mapped[Optional[int]] = mapped_column(Integer, nullable=True)  # для DEVICES
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)

    offers: Mapped[list["PlanOffer"]] = relationship(
        "PlanOffer", back_populates="plan", lazy="selectin"
    )


class PlanOffer(Base):
    """Вариант длительности тарифа (30/90/365 дней)."""

    __tablename__ = "plan_offers"

    id: Mapped[int] = mapped_column(primary_key=True, autoincrement=True)
    plan_id: Mapped[int] = mapped_column(ForeignKey("plans.id"), nullable=False)
    duration_days: Mapped[int] = mapped_column(Integer, nullable=False)  # 30, 90, 365
    price: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    currency: Mapped[str] = mapped_column(String(3), default="RUB", nullable=False)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=datetime.utcnow)

    plan: Mapped["Plan"] = relationship("Plan", back_populates="offers")
