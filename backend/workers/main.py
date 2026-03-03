"""Worker service entrypoint (Stage 5)."""

from __future__ import annotations

import logging

from backend.core.config import get_settings
from backend.services.bot_service import TelegramGateway
from backend.services.notifications_service import NotificationsService
from backend.workers.scheduler import WorkerScheduler


def _configure_logging() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s %(message)s",
    )


def main() -> None:
    _configure_logging()
    settings = get_settings()
    gateway = TelegramGateway(
        token=settings.TELEGRAM_BOT_TOKEN,
        outbound_enabled=settings.BOT_OUTBOUND_ENABLED,
    )
    notifications = NotificationsService(gateway=gateway)
    scheduler = WorkerScheduler(notifications=notifications)
    scheduler.run()


if __name__ == "__main__":
    main()
