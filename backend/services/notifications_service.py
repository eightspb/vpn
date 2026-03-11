"""Notifications outbox with retry/backoff and DLQ."""

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from datetime import datetime, timedelta
from typing import Any, Optional

from sqlalchemy import and_, func, select
from sqlalchemy.orm import Session

from backend.core.config import get_settings
from backend.models import (
    BroadcastCampaign,
    NotificationEvent,
    Subscription,
    SubscriptionStatus,
    TelegramProfile,
)
from backend.services.audit_service import write_audit_event
from backend.services.bot_service import TelegramGateway
from backend.services.worker_metrics_service import push_dlq

logger = logging.getLogger(__name__)


@dataclass
class QueueCounters:
    processed: int = 0
    success: int = 0
    errors: int = 0
    dlq: int = 0


class NotificationsService:
    """Queue producer/consumer for user notifications."""

    def __init__(self, gateway: TelegramGateway):
        self._gateway = gateway
        self._settings = get_settings()

    def enqueue_notification(
        self,
        session: Session,
        *,
        user_id: int,
        event_type: str,
        text: str,
        dedupe_key: str,
        subscription_id: Optional[int] = None,
        campaign_id: Optional[int] = None,
    ) -> Optional[NotificationEvent]:
        exists = session.scalar(
            select(NotificationEvent.id).where(NotificationEvent.dedupe_key == dedupe_key)
        )
        if exists is not None:
            return None

        max_attempts = max(1, int(self._settings.WORKER_MAX_RETRIES))
        event = NotificationEvent(
            user_id=user_id,
            subscription_id=subscription_id,
            campaign_id=campaign_id,
            event_type=event_type,
            channel="telegram",
            dedupe_key=dedupe_key,
            payload=json.dumps({"text": text}, ensure_ascii=False),
            status="pending",
            attempts=0,
            max_attempts=max_attempts,
            next_retry_at=datetime.utcnow(),
        )
        session.add(event)
        return event

    def enqueue_expiration_notifications(self, session: Session, days_before: int) -> int:
        now = datetime.utcnow()
        day_start = (now + timedelta(days=days_before)).replace(hour=0, minute=0, second=0, microsecond=0)
        day_end = day_start + timedelta(days=1)

        rows = session.execute(
            select(Subscription.id, Subscription.user_id, Subscription.expires_at)
            .where(
                and_(
                    Subscription.status == SubscriptionStatus.ACTIVE,
                    Subscription.expires_at >= day_start,
                    Subscription.expires_at < day_end,
                )
            )
            .order_by(Subscription.id.asc())
        ).all()

        created = 0
        for sub_id, user_id, expires_at in rows:
            dedupe_key = f"expiring:{sub_id}:d{days_before}"
            text = (
                f"Напоминание: подписка истекает через {days_before} дн. "
                f"(до {expires_at:%Y-%m-%d}). Продлите тариф заранее."
            )
            if self.enqueue_notification(
                session=session,
                user_id=int(user_id),
                event_type="subscription_expiring",
                text=text,
                dedupe_key=dedupe_key,
                subscription_id=int(sub_id),
            ):
                created += 1
        return created

    def enqueue_expired_notifications(self, session: Session) -> int:
        now = datetime.utcnow()
        rows = session.execute(
            select(Subscription.id, Subscription.user_id, Subscription.expires_at)
            .where(
                and_(
                    Subscription.expires_at <= now,
                    Subscription.status.in_((SubscriptionStatus.ACTIVE, SubscriptionStatus.PENDING)),
                )
            )
            .order_by(Subscription.id.asc())
        ).all()

        created = 0
        for sub_id, user_id, expires_at in rows:
            dedupe_key = f"expired:{sub_id}"
            text = (
                f"Подписка истекла ({expires_at:%Y-%m-%d}). "
                "Чтобы снова пользоваться VPN, продлите тариф."
            )
            if self.enqueue_notification(
                session=session,
                user_id=int(user_id),
                event_type="subscription_expired",
                text=text,
                dedupe_key=dedupe_key,
                subscription_id=int(sub_id),
            ):
                created += 1
        return created

    def deliver_pending(self, session: Session, *, limit: int = 100) -> QueueCounters:
        now = datetime.utcnow()
        rows = session.scalars(
            select(NotificationEvent)
            .where(
                and_(
                    NotificationEvent.status.in_(("pending", "retry")),
                    NotificationEvent.next_retry_at <= now,
                )
            )
            .order_by(NotificationEvent.id.asc())
            .limit(max(1, min(limit, 500)))
        ).all()

        counters = QueueCounters(processed=len(rows))
        for event in rows:
            payload = self._safe_payload(event.payload)
            profile = session.scalar(
                select(TelegramProfile).where(TelegramProfile.user_id == event.user_id)
            )
            if profile is None:
                self._mark_failed(
                    session=session,
                    event=event,
                    error="telegram profile not found",
                    payload=payload,
                )
                counters.errors += 1
                if event.status == "dead":
                    counters.dlq += 1
                continue

            ok = self._gateway.send_message(profile.chat_id, payload.get("text", ""))
            if ok:
                event.status = "sent"
                event.sent_at = datetime.utcnow()
                event.last_error = None
                counters.success += 1
                write_audit_event(
                    session=session,
                    action="notification_sent",
                    user_id=event.user_id,
                    target=f"notification:{event.id}",
                    details={"event_type": event.event_type, "channel": event.channel},
                    ip_address=None,
                )
                self._update_campaign_stats(session=session, campaign_id=event.campaign_id, success=True)
                continue

            self._mark_failed(
                session=session,
                event=event,
                error="telegram send failed",
                payload=payload,
            )
            counters.errors += 1
            if event.status == "dead":
                counters.dlq += 1
            self._update_campaign_stats(
                session=session,
                campaign_id=event.campaign_id,
                failed=event.status == "dead",
            )

        return counters

    def _mark_failed(
        self,
        *,
        session: Session,
        event: NotificationEvent,
        error: str,
        payload: dict[str, Any],
    ) -> None:
        event.attempts += 1
        event.last_error = error
        if event.attempts >= event.max_attempts:
            event.status = "dead"
            push_dlq(
                session=session,
                task_name="notifications.deliver",
                item_key=event.dedupe_key,
                payload=payload,
                error_message=error,
                attempts=event.attempts,
            )
            return
        event.status = "retry"
        backoff = self._compute_backoff_seconds(event.attempts)
        event.next_retry_at = datetime.utcnow() + timedelta(seconds=backoff)

    def _compute_backoff_seconds(self, attempt: int) -> int:
        base = max(1, int(self._settings.WORKER_RETRY_BASE_SECONDS))
        cap = max(base, int(self._settings.WORKER_RETRY_MAX_SECONDS))
        return min(cap, base * (2 ** max(0, attempt - 1)))

    def _safe_payload(self, raw: str) -> dict[str, Any]:
        try:
            data = json.loads(raw or "{}")
            if isinstance(data, dict):
                return data
        except Exception as e:
            logger.warning(f"Failed to parse notification payload: {e}")
        return {}

    def _update_campaign_stats(
        self,
        *,
        session: Session,
        campaign_id: Optional[int],
        success: bool = False,
        failed: bool = False,
    ) -> None:
        if campaign_id is None:
            return
        campaign = session.get(BroadcastCampaign, campaign_id)
        if campaign is None:
            return
        if campaign.started_at is None:
            campaign.started_at = datetime.utcnow()
        if success:
            campaign.sent_count += 1
        if failed:
            campaign.failed_count += 1

        done_count = campaign.sent_count + campaign.failed_count
        if campaign.total_targets > 0 and done_count >= campaign.total_targets:
            campaign.status = "done" if campaign.failed_count == 0 else "done_with_errors"
            campaign.finished_at = datetime.utcnow()

    def cleanup_stale(self, session: Session) -> dict[str, int]:
        keep_days = max(1, int(self._settings.WORKER_CLEANUP_KEEP_DAYS))
        cutoff = datetime.utcnow() - timedelta(days=keep_days)

        old_notifications = session.scalar(
            select(func.count(NotificationEvent.id)).where(
                and_(
                    NotificationEvent.created_at < cutoff,
                    NotificationEvent.status.in_(("sent", "dead")),
                )
            )
        ) or 0
        session.query(NotificationEvent).filter(
            and_(
                NotificationEvent.created_at < cutoff,
                NotificationEvent.status.in_(("sent", "dead")),
            )
        ).delete(synchronize_session=False)

        return {"notifications_deleted": int(old_notifications)}
