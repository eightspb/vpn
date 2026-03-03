"""Billing domain service (payment providers, trial, promocodes, webhooks)."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from decimal import Decimal
from typing import Any, Optional
import secrets

from sqlalchemy import and_, select
from sqlalchemy.orm import Session

from backend.integrations.manual_payment_provider import ManualPaymentProvider
from backend.integrations.payment_gateway import ParsedWebhookEvent, PaymentGateway
from backend.integrations.test_payment_provider import TestPaymentProvider
from backend.models import PaymentWebhookEvent, PlanOffer, Promocode, Subscription, Transaction, TrialActivation
from backend.models.enums import PromocodeKind, SubscriptionStatus, TransactionStatus
from backend.services.audit_service import write_audit_event


TRIAL_PERIOD_DAYS_DEFAULT = 30
TRIAL_COOLDOWN_DAYS_DEFAULT = 90


@dataclass
class CheckoutResult:
    transaction_id: int
    external_id: str
    payment_url: str
    provider: str
    charged_amount: Decimal
    currency: str
    is_trial: bool


@dataclass
class WebhookProcessResult:
    found: bool
    duplicate: bool
    transaction_id: Optional[int]
    status: Optional[str]


class BillingService:
    """Production-oriented billing layer with idempotent webhook processing."""

    def __init__(self, gateways: list[PaymentGateway]) -> None:
        self._gateways = {gateway.provider_name: gateway for gateway in gateways}

    def create_checkout(
        self,
        session: Session,
        *,
        user_id: int,
        offer_id: int,
        provider: str,
        ip_address: Optional[str] = None,
        promocode_code: Optional[str] = None,
        trial: bool = False,
    ) -> CheckoutResult:
        offer = session.get(PlanOffer, offer_id)
        if offer is None:
            raise ValueError("offer not found")
        gateway = self._gateway(provider)
        now = datetime.utcnow()

        original_amount = Decimal(str(offer.price))
        charged_amount = original_amount
        discount_amount = Decimal("0.00")
        promocode: Optional[Promocode] = None
        if promocode_code:
            promocode, discount_amount = self._apply_promocode(
                session=session,
                code=promocode_code,
                original_amount=original_amount,
            )
            charged_amount = original_amount - discount_amount

        if trial:
            self._ensure_trial_allowed(session=session, user_id=user_id, ip_address=ip_address)
            charged_amount = Decimal("0.00")
            discount_amount = original_amount

        subscription = Subscription(
            user_id=user_id,
            plan_offer_id=offer.id,
            status=SubscriptionStatus.PENDING,
            started_at=now,
            expires_at=now + timedelta(days=offer.duration_days),
        )
        session.add(subscription)
        session.flush()

        transaction = Transaction(
            subscription_id=subscription.id,
            amount=charged_amount,
            original_amount=original_amount,
            discount_amount=discount_amount,
            currency=offer.currency,
            provider="trial" if trial else gateway.provider_name,
            status=TransactionStatus.PENDING if not trial else TransactionStatus.COMPLETED,
            idempotency_key=secrets.token_urlsafe(18),
            promocode_id=promocode.id if promocode else None,
            is_trial=bool(trial),
        )
        session.add(transaction)
        session.flush()

        if trial:
            self._activate_subscription(session=session, transaction=transaction, at=now)
            write_audit_event(
                session=session,
                action="trial_activated",
                user_id=user_id,
                target=f"subscription:{subscription.id}",
                details={"transaction_id": transaction.id, "offer_id": offer_id},
                ip_address=ip_address,
            )
            return CheckoutResult(
                transaction_id=transaction.id,
                external_id=f"trial_{transaction.id}",
                payment_url="",
                provider="trial",
                charged_amount=charged_amount,
                currency=offer.currency,
                is_trial=True,
            )

        payment = gateway.create_payment(
            transaction_id=transaction.id,
            amount=str(charged_amount),
            currency=offer.currency,
            metadata={"user_id": user_id, "offer_id": offer_id},
        )
        transaction.external_id = payment.external_id

        write_audit_event(
            session=session,
            action="payment_created",
            user_id=user_id,
            target=f"transaction:{transaction.id}",
            details={
                "provider": transaction.provider,
                "external_id": payment.external_id,
                "promocode": promocode.code if promocode else None,
                "trial": False,
            },
            ip_address=ip_address,
        )
        return CheckoutResult(
            transaction_id=transaction.id,
            external_id=payment.external_id,
            payment_url=payment.payment_url,
            provider=gateway.provider_name,
            charged_amount=charged_amount,
            currency=offer.currency,
            is_trial=False,
        )

    def process_webhook(
        self,
        session: Session,
        *,
        provider: str,
        payload: dict[str, Any],
        ip_address: Optional[str] = None,
    ) -> WebhookProcessResult:
        gateway = self._gateway(provider)
        parsed = gateway.parse_webhook(payload)
        return self.apply_event(
            session=session,
            provider=provider,
            event=parsed,
            ip_address=ip_address,
            source="webhook",
        )

    def confirm_payment(
        self,
        session: Session,
        *,
        provider: str,
        external_id: str,
        ip_address: Optional[str],
        source: str,
    ) -> WebhookProcessResult:
        parsed = ParsedWebhookEvent(
            event_id=f"{provider}:internal:{source}:{external_id}",
            external_id=external_id,
            status=TransactionStatus.COMPLETED,
            raw_payload={"source": source, "external_id": external_id},
        )
        return self.apply_event(
            session=session,
            provider=provider,
            event=parsed,
            ip_address=ip_address,
            source=source,
        )

    def apply_event(
        self,
        session: Session,
        *,
        provider: str,
        event: ParsedWebhookEvent,
        ip_address: Optional[str],
        source: str,
    ) -> WebhookProcessResult:
        duplicate = session.scalar(
            select(PaymentWebhookEvent).where(
                and_(
                    PaymentWebhookEvent.provider == provider,
                    PaymentWebhookEvent.event_id == event.event_id,
                )
            )
        )
        if duplicate is not None:
            return WebhookProcessResult(
                found=True,
                duplicate=True,
                transaction_id=duplicate.transaction_id,
                status=duplicate.status,
            )

        transaction = session.scalar(
            select(Transaction).where(
                and_(Transaction.provider == provider, Transaction.external_id == event.external_id)
            )
        )
        if transaction is None:
            return WebhookProcessResult(found=False, duplicate=False, transaction_id=None, status=None)

        session.add(
            PaymentWebhookEvent(
                provider=provider,
                event_id=event.event_id,
                external_id=event.external_id,
                status=event.status.value,
                transaction_id=transaction.id,
            )
        )

        prev_status = transaction.status
        next_status = self._next_status(prev_status, event.status)
        transaction.status = next_status

        if prev_status != next_status:
            write_audit_event(
                session=session,
                action="payment_status_updated",
                user_id=None,
                target=f"transaction:{transaction.id}",
                details={
                    "provider": provider,
                    "external_id": transaction.external_id,
                    "from": prev_status.value,
                    "to": next_status.value,
                    "source": source,
                },
                ip_address=ip_address,
            )

        if next_status == TransactionStatus.COMPLETED and prev_status != TransactionStatus.COMPLETED:
            self._activate_subscription(session=session, transaction=transaction, at=datetime.utcnow())
            subscription = session.get(Subscription, transaction.subscription_id) if transaction.subscription_id else None
            write_audit_event(
                session=session,
                action="payment_confirmed",
                user_id=subscription.user_id if subscription else None,
                target=f"transaction:{transaction.id}",
                details={"provider": provider, "external_id": transaction.external_id, "source": source},
                ip_address=ip_address,
            )
        if next_status == TransactionStatus.REFUNDED:
            subscription = session.get(Subscription, transaction.subscription_id) if transaction.subscription_id else None
            if subscription is not None:
                subscription.status = SubscriptionStatus.CANCELLED

        return WebhookProcessResult(
            found=True,
            duplicate=False,
            transaction_id=transaction.id,
            status=transaction.status.value,
        )

    def _activate_subscription(self, session: Session, transaction: Transaction, at: datetime) -> None:
        if transaction.subscription_id is None:
            return
        subscription = session.get(Subscription, transaction.subscription_id)
        if subscription is None:
            return
        offer = session.get(PlanOffer, subscription.plan_offer_id)
        if offer is None:
            return
        subscription.status = SubscriptionStatus.ACTIVE
        subscription.started_at = at
        subscription.expires_at = at + timedelta(days=offer.duration_days)
        write_audit_event(
            session=session,
            action="subscription_activated",
            user_id=subscription.user_id,
            target=f"subscription:{subscription.id}",
            details={"transaction_id": transaction.id, "plan_offer_id": subscription.plan_offer_id},
            ip_address=None,
        )

    def _apply_promocode(
        self,
        *,
        session: Session,
        code: str,
        original_amount: Decimal,
    ) -> tuple[Promocode, Decimal]:
        clean_code = code.strip().upper()
        promo = session.scalar(select(Promocode).where(Promocode.code == clean_code))
        if promo is None:
            raise ValueError("promocode not found")
        if not promo.is_active:
            raise ValueError("promocode inactive")
        if promo.expires_at and promo.expires_at <= datetime.utcnow():
            raise ValueError("promocode expired")
        if promo.usage_limit is not None and promo.used_count >= promo.usage_limit:
            raise ValueError("promocode usage limit reached")

        if promo.kind == PromocodeKind.FIXED:
            discount = Decimal(str(promo.value))
        else:
            discount = (original_amount * Decimal(str(promo.value)) / Decimal("100")).quantize(Decimal("0.01"))
        discount = max(Decimal("0.00"), min(discount, original_amount))

        promo.used_count += 1
        return promo, discount

    def _ensure_trial_allowed(self, *, session: Session, user_id: int, ip_address: Optional[str]) -> None:
        now = datetime.utcnow()
        period_key = now.strftime("%Y-%m")
        recent_cutoff = now - timedelta(days=TRIAL_COOLDOWN_DAYS_DEFAULT)
        recent = session.scalar(
            select(TrialActivation).where(
                and_(TrialActivation.user_id == user_id, TrialActivation.created_at >= recent_cutoff)
            )
        )
        if recent is not None:
            raise ValueError("trial cooldown active")
        same_period = session.scalar(
            select(TrialActivation).where(
                and_(TrialActivation.user_id == user_id, TrialActivation.period_key == period_key)
            )
        )
        if same_period is not None:
            raise ValueError("trial already used in this period")
        session.add(TrialActivation(user_id=user_id, period_key=period_key, ip_address=ip_address))

    def _gateway(self, provider: str) -> PaymentGateway:
        gateway = self._gateways.get(provider)
        if gateway is None:
            raise ValueError(f"unsupported provider: {provider}")
        return gateway

    def _next_status(self, current: TransactionStatus, incoming: TransactionStatus) -> TransactionStatus:
        allowed: dict[TransactionStatus, set[TransactionStatus]] = {
            TransactionStatus.PENDING: {
                TransactionStatus.PENDING,
                TransactionStatus.COMPLETED,
                TransactionStatus.CANCELED,
                TransactionStatus.FAILED,
            },
            TransactionStatus.COMPLETED: {
                TransactionStatus.COMPLETED,
                TransactionStatus.REFUNDED,
            },
            TransactionStatus.CANCELED: {TransactionStatus.CANCELED},
            TransactionStatus.FAILED: {TransactionStatus.FAILED},
            TransactionStatus.REFUNDED: {TransactionStatus.REFUNDED},
        }
        if incoming in allowed.get(current, set()):
            return incoming
        return current


def build_billing_service() -> BillingService:
    return BillingService(
        gateways=[
            TestPaymentProvider(),
            ManualPaymentProvider(),
        ]
    )
