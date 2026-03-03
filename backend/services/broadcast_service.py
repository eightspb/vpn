"""Broadcast v1 service: segment targeting and campaign journal."""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from sqlalchemy import and_, select
from sqlalchemy.orm import Session

from backend.models import BroadcastCampaign, Subscription, SubscriptionStatus, TelegramProfile
from backend.services.notifications_service import NotificationsService

BroadcastSegment = Literal["all", "active", "expired"]


class BroadcastService:
    """Creates campaigns and enqueues per-user notification events."""

    def __init__(self, notifications: NotificationsService):
        self._notifications = notifications

    def create_campaign(
        self,
        session: Session,
        *,
        segment: BroadcastSegment,
        message: str,
        created_by_user_id: int | None,
    ) -> BroadcastCampaign:
        clean_segment = segment.strip().lower()
        if clean_segment not in {"all", "active", "expired"}:
            raise ValueError("unsupported segment")
        clean_message = message.strip()
        if not clean_message:
            raise ValueError("empty message")

        campaign = BroadcastCampaign(
            segment=clean_segment,
            message=clean_message,
            status="queued",
            created_by_user_id=created_by_user_id,
            created_at=datetime.utcnow(),
        )
        session.add(campaign)
        session.flush()

        user_ids = self._target_user_ids(session=session, segment=clean_segment)
        created = 0
        for user_id in user_ids:
            dedupe_key = f"broadcast:{campaign.id}:user:{user_id}"
            item = self._notifications.enqueue_notification(
                session=session,
                user_id=user_id,
                event_type="broadcast",
                text=clean_message,
                dedupe_key=dedupe_key,
                campaign_id=campaign.id,
            )
            if item is not None:
                created += 1

        campaign.total_targets = created
        campaign.status = "queued" if created > 0 else "done"
        if created == 0:
            campaign.started_at = datetime.utcnow()
            campaign.finished_at = campaign.started_at
        return campaign

    def list_campaigns(self, session: Session, limit: int = 100) -> list[BroadcastCampaign]:
        return session.scalars(
            select(BroadcastCampaign).order_by(BroadcastCampaign.id.desc()).limit(max(1, min(limit, 500)))
        ).all()

    def _target_user_ids(self, *, session: Session, segment: str) -> list[int]:
        if segment == "all":
            rows = session.scalars(select(TelegramProfile.user_id).order_by(TelegramProfile.user_id.asc())).all()
            return [int(item) for item in rows]

        now = datetime.utcnow()
        if segment == "active":
            rows = session.scalars(
                select(Subscription.user_id)
                .where(
                    and_(
                        Subscription.status == SubscriptionStatus.ACTIVE,
                        Subscription.expires_at > now,
                    )
                )
                .distinct()
            ).all()
            return [int(item) for item in rows]

        rows = session.scalars(
            select(Subscription.user_id)
            .where(
                and_(
                    Subscription.status.in_((SubscriptionStatus.EXPIRED, SubscriptionStatus.CANCELLED)),
                    Subscription.expires_at <= now,
                )
            )
            .distinct()
        ).all()
        return [int(item) for item in rows]
