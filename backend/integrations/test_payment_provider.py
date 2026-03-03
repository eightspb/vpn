"""Test payment provider для billing v2."""

from datetime import datetime
import secrets
from typing import Any

from backend.integrations.payment_gateway import ParsedWebhookEvent, PaymentSession
from backend.models.enums import TransactionStatus

_WEBHOOK_STATUSES: dict[str, TransactionStatus] = {
    "pending": TransactionStatus.PENDING,
    "completed": TransactionStatus.COMPLETED,
    "canceled": TransactionStatus.CANCELED,
    "failed": TransactionStatus.FAILED,
    "refunded": TransactionStatus.REFUNDED,
}


class TestPaymentProvider:
    """Генерирует фейковую платёжную сессию и парсит webhook payload."""

    provider_name = "test"

    def create_payment(
        self,
        transaction_id: int,
        amount: str,
        currency: str,
        metadata: dict[str, Any] | None = None,
    ) -> PaymentSession:
        suffix = secrets.token_hex(4)
        external_id = f"testpay_{transaction_id}_{suffix}"
        _ = metadata  # reserved for unified PaymentGateway signature
        return PaymentSession(
            external_id=external_id,
            payment_url=f"https://test-payments.local/pay/{external_id}?amount={amount}&currency={currency}",
            created_at=datetime.utcnow(),
        )

    def parse_webhook(self, payload: dict[str, Any]) -> ParsedWebhookEvent:
        external_id = str(payload.get("external_id") or "").strip()
        if not external_id:
            raise ValueError("external_id required")
        raw_status = str(payload.get("status") or "completed").strip().lower()
        status = _WEBHOOK_STATUSES.get(raw_status)
        if status is None:
            raise ValueError(f"unsupported status: {raw_status}")
        event_id = str(payload.get("event_id") or "").strip() or f"test:{external_id}:{raw_status}"
        return ParsedWebhookEvent(
            event_id=event_id,
            external_id=external_id,
            status=status,
            raw_payload=payload,
        )
