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
