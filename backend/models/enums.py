"""Enum'ы для доменной модели."""

import enum


class PlanKind(str, enum.Enum):
    """Тип тарифного плана."""
    UNLIMITED = "UNLIMITED"
    TRAFFIC = "TRAFFIC"
    DEVICES = "DEVICES"


class RoleEnum(str, enum.Enum):
    """Роль пользователя."""
    OWNER = "owner"
    ADMIN = "admin"
    OPERATOR = "operator"
    READONLY = "readonly"
    USER = "user"
    SUPPORT = "support"


class SubscriptionStatus(str, enum.Enum):
    """Статус подписки."""
    ACTIVE = "active"
    EXPIRED = "expired"
    CANCELLED = "cancelled"
    PENDING = "pending"


class TransactionStatus(str, enum.Enum):
    """Статус платежной транзакции."""

    PENDING = "pending"
    COMPLETED = "completed"
    CANCELED = "canceled"
    FAILED = "failed"
    REFUNDED = "refunded"


class PromocodeKind(str, enum.Enum):
    """Тип промокода."""

    FIXED = "fixed"
    PERCENT = "percent"
