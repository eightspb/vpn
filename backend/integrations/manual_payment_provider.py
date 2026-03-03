"""Second provider for billing abstraction (manual invoice)."""

from datetime import datetime
import secrets
from typing import Any

from backend.integrations.payment_gateway import ParsedWebhookEvent, PaymentSession
from backend.models.enums import TransactionStatus


class ManualPaymentProvider:
    """Provider with explicit invoice_id/event_id contract."""

    provider_name = "manual"

    def create_payment(
        self,
        transaction_id: int,
        amount: str,
        currency: str,
        metadata: dict[str, Any] | None = None,
    ) -> PaymentSession:
        invoice = f"inv_{transaction_id}_{secrets.token_hex(3)}"
        note = ""
        if metadata and metadata.get("user_id"):
            note = f"&user_id={metadata['user_id']}"
        return PaymentSession(
            external_id=invoice,
            payment_url=f"https://manual-pay.local/invoice/{invoice}?amount={amount}&currency={currency}{note}",
            created_at=datetime.utcnow(),
        )

    def parse_webhook(self, payload: dict[str, Any]) -> ParsedWebhookEvent:
        external_id = str(payload.get("invoice_id") or payload.get("external_id") or "").strip()
        event_id = str(payload.get("callback_id") or payload.get("event_id") or "").strip()
        raw_status = str(payload.get("state") or payload.get("status") or "").strip().lower()
        if not external_id:
            raise ValueError("invoice_id required")
        if not event_id:
            raise ValueError("callback_id required")
        mapping = {
            "pending": TransactionStatus.PENDING,
            "paid": TransactionStatus.COMPLETED,
            "completed": TransactionStatus.COMPLETED,
            "failed": TransactionStatus.FAILED,
            "canceled": TransactionStatus.CANCELED,
            "refunded": TransactionStatus.REFUNDED,
        }
        status = mapping.get(raw_status)
        if status is None:
            raise ValueError(f"unsupported state: {raw_status}")
        return ParsedWebhookEvent(
            event_id=event_id,
            external_id=external_id,
            status=status,
            raw_payload=payload,
        )
