"""Конфигурация приложения из .env."""

from functools import lru_cache
from typing import Optional

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Настройки из переменных окружения."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    APP_ENV: str = "development"
    APP_HOST: str = "0.0.0.0"
    APP_PORT: int = 8000
    DATABASE_URL: Optional[str] = None
    REDIS_URL: Optional[str] = None
    TELEGRAM_BOT_TOKEN: Optional[str] = None
    TELEGRAM_WEBHOOK_SECRET_TOKEN: Optional[str] = None
    BOT_INTERNAL_API_TOKEN: Optional[str] = None
    TEST_PAYMENT_WEBHOOK_SECRET: Optional[str] = None
    BOT_SERVICE_HOST: str = "0.0.0.0"
    BOT_SERVICE_PORT: int = 8010
    BOT_OUTBOUND_ENABLED: bool = True
    BOT_PAYMENT_PROVIDER: str = "test"
    LEGACY_ADMIN_BASE_URL: str = "http://127.0.0.1:8081"
    LEGACY_ADMIN_USERNAME: Optional[str] = None
    LEGACY_ADMIN_PASSWORD: Optional[str] = None
    CORS_ALLOWED_ORIGINS: str = ""

    WORKER_NOTIFY_3D_MINUTES: int = 60
    WORKER_NOTIFY_1D_MINUTES: int = 60
    WORKER_NOTIFY_EXPIRED_MINUTES: int = 60
    WORKER_CLEANUP_MINUTES: int = 360
    WORKER_SYNC_MINUTES: int = 30
    WORKER_DELIVERY_SECONDS: int = 20
    WORKER_DELIVERY_BATCH_SIZE: int = 100
    WORKER_MAX_RETRIES: int = 5
    WORKER_RETRY_BASE_SECONDS: int = 30
    WORKER_RETRY_MAX_SECONDS: int = 1800
    WORKER_CLEANUP_KEEP_DAYS: int = 30
    WORKER_STALE_PEER_MINUTES: int = 1440


@lru_cache
def get_settings() -> Settings:
    """Единственный инстанс настроек (кэшируется)."""
    return Settings()
