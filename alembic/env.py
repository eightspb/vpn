"""Alembic env.py — конфигурация миграций Postgres."""

import os
from logging.config import fileConfig

from dotenv import load_dotenv
from sqlalchemy import engine_from_config
from sqlalchemy import pool
from alembic import context

# Загружаем .env из корня проекта
load_dotenv()

# Alembic Config object
config = context.config

# Настройка логирования
if config.config_file_name is not None:
    fileConfig(config.config_file_name)

# Импортируем Base и все модели для autogenerate
from backend.db.session import Base
from backend.models import (
    User,
    Plan,
    PlanOffer,
    Subscription,
    Transaction,
    Promocode,
    TrialActivation,
    PaymentWebhookEvent,
    Setting,
    AuditLog,
    PeerDevice,
    TelegramProfile,
    NotificationEvent,
    BroadcastCampaign,
    WorkerJobRun,
    WorkerDeadLetter,
)

target_metadata = Base.metadata


def get_url() -> str:
    """URL БД из DATABASE_URL или alembic.ini."""
    url = os.environ.get("DATABASE_URL")
    if url:
        return url
    return config.get_main_option(
        "sqlalchemy.url",
        "postgresql+psycopg2://vpn:secret@localhost:5432/vpn",
    )


def run_migrations_offline() -> None:
    """Run migrations in 'offline' mode (без подключения к БД)."""
    url = get_url()
    context.configure(
        url=url,
        target_metadata=target_metadata,
        literal_binds=True,
        dialect_opts={"paramstyle": "named"},
    )

    with context.begin_transaction():
        context.run_migrations()


def run_migrations_online() -> None:
    """Run migrations in 'online' mode (с подключением к БД)."""
    configuration = config.get_section(config.config_ini_section, {}) or {}
    configuration["sqlalchemy.url"] = get_url()

    connectable = engine_from_config(
        configuration,
        prefix="sqlalchemy.",
        poolclass=pool.NullPool,
    )

    with connectable.connect() as connection:
        context.configure(
            connection=connection,
            target_metadata=target_metadata,
        )

        with context.begin_transaction():
            context.run_migrations()


if context.is_offline_mode():
    run_migrations_offline()
else:
    run_migrations_online()
