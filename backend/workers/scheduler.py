"""Worker scheduler and periodic Stage 5 jobs."""

from __future__ import annotations

import logging
from datetime import datetime, timedelta
from typing import Any, Callable

from apscheduler.schedulers.blocking import BlockingScheduler
from apscheduler.triggers.interval import IntervalTrigger
from sqlalchemy import and_, select

from backend.core.config import get_settings
from backend.db.session import get_session
from backend.models import PeerDevice, Subscription, SubscriptionStatus
from backend.services.notifications_service import NotificationsService
from backend.services.worker_metrics_service import JobCounters, save_job_run

logger = logging.getLogger(__name__)


class WorkerScheduler:
    """Single-process scheduler for periodic jobs + queue delivery."""

    def __init__(self, notifications: NotificationsService):
        self._settings = get_settings()
        self._notifications = notifications
        self._scheduler = BlockingScheduler(timezone="UTC")

    def configure(self) -> None:
        self._add_interval_job("notify_expiring_3d", self._notify_expiring_3d, self._settings.WORKER_NOTIFY_3D_MINUTES)
        self._add_interval_job("notify_expiring_1d", self._notify_expiring_1d, self._settings.WORKER_NOTIFY_1D_MINUTES)
        self._add_interval_job("notify_expired", self._notify_expired, self._settings.WORKER_NOTIFY_EXPIRED_MINUTES)
        self._add_interval_job("cleanup_stale", self._cleanup_stale, self._settings.WORKER_CLEANUP_MINUTES)
        self._add_interval_job("sync_subscription_states", self._sync_subscription_states, self._settings.WORKER_SYNC_MINUTES)
        self._add_interval_job("deliver_notifications", self._deliver_notifications, self._settings.WORKER_DELIVERY_SECONDS, seconds=True)

    def run(self) -> None:
        self.configure()
        logger.info("worker started jobs=%s", ",".join([job.id for job in self._scheduler.get_jobs()]))
        self._scheduler.start()

    def _add_interval_job(
        self,
        name: str,
        func: Callable[[], JobCounters],
        value: int,
        *,
        seconds: bool = False,
    ) -> None:
        interval = max(1, int(value))
        trigger = IntervalTrigger(seconds=interval) if seconds else IntervalTrigger(minutes=interval)
        self._scheduler.add_job(
            lambda: self._run_job(name, func),
            trigger=trigger,
            id=name,
            replace_existing=True,
            max_instances=1,
            coalesce=True,
            misfire_grace_time=30,
        )

    def _run_job(self, name: str, func: Callable[[], JobCounters]) -> None:
        started = datetime.utcnow()
        status = "ok"
        counters = JobCounters()
        details: dict[str, Any] = {}
        error_message = None
        try:
            counters = func()
            details = {
                "processed": counters.processed,
                "success": counters.success,
                "errors": counters.errors,
            }
            logger.info(
                "task=%s status=ok processed=%s success=%s errors=%s",
                name,
                counters.processed,
                counters.success,
                counters.errors,
            )
        except Exception as exc:
            status = "error"
            error_message = str(exc)
            logger.exception("task=%s status=error", name)
            counters.errors = max(1, counters.errors)
        finally:
            finished = datetime.utcnow()
            with get_session() as session:
                save_job_run(
                    session=session,
                    task_name=name,
                    status=status,
                    started_at=started,
                    finished_at=finished,
                    counters=counters,
                    details=details,
                    error_message=error_message,
                )

    def _notify_expiring_3d(self) -> JobCounters:
        with get_session() as session:
            created = self._notifications.enqueue_expiration_notifications(session, days_before=3)
            return JobCounters(processed=created, success=created, errors=0)

    def _notify_expiring_1d(self) -> JobCounters:
        with get_session() as session:
            created = self._notifications.enqueue_expiration_notifications(session, days_before=1)
            return JobCounters(processed=created, success=created, errors=0)

    def _notify_expired(self) -> JobCounters:
        with get_session() as session:
            created = self._notifications.enqueue_expired_notifications(session)
            return JobCounters(processed=created, success=created, errors=0)

    def _cleanup_stale(self) -> JobCounters:
        with get_session() as session:
            stats = self._notifications.cleanup_stale(session)
            deleted = int(stats.get("notifications_deleted", 0))
            return JobCounters(processed=deleted, success=deleted, errors=0)

    def _deliver_notifications(self) -> JobCounters:
        with get_session() as session:
            stats = self._notifications.deliver_pending(session=session, limit=self._settings.WORKER_DELIVERY_BATCH_SIZE)
            return JobCounters(
                processed=stats.processed,
                success=stats.success,
                errors=stats.errors,
            )

    def _sync_subscription_states(self) -> JobCounters:
        with get_session() as session:
            now = datetime.utcnow()
            processed = 0
            success = 0
            for sub in session.scalars(select(Subscription).order_by(Subscription.id.asc())).all():
                processed += 1
                expected_status = sub.status
                if sub.expires_at <= now and sub.status in {SubscriptionStatus.ACTIVE, SubscriptionStatus.PENDING}:
                    expected_status = SubscriptionStatus.EXPIRED
                if sub.expires_at > now and sub.status == SubscriptionStatus.EXPIRED:
                    expected_status = SubscriptionStatus.ACTIVE
                if expected_status != sub.status:
                    sub.status = expected_status
                    success += 1

                peer_rows = session.scalars(
                    select(PeerDevice).where(PeerDevice.subscription_id == sub.id)
                ).all()
                peer_status = "active" if sub.status == SubscriptionStatus.ACTIVE else "inactive"
                for peer in peer_rows:
                    if peer.status != peer_status:
                        peer.status = peer_status
                        peer.updated_at = now

            stale_peers = session.scalars(
                select(PeerDevice)
                .where(
                    and_(
                        PeerDevice.subscription_id.is_(None),
                        PeerDevice.updated_at < (now - self._stale_peer_window()),
                        PeerDevice.status != "inactive",
                    )
                )
            ).all()
            for peer in stale_peers:
                processed += 1
                peer.status = "inactive"
                peer.updated_at = now
                success += 1
            return JobCounters(processed=processed, success=success, errors=0)

    def _stale_peer_window(self) -> timedelta:
        minutes = max(1, int(self._settings.WORKER_STALE_PEER_MINUTES))
        return timedelta(minutes=minutes)
