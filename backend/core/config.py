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


@lru_cache
def get_settings() -> Settings:
    """Единственный инстанс настроек (кэшируется)."""
    return Settings()
