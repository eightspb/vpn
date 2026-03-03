"""Payment gateway abstraction for billing v2."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime
from typing import Any, Protocol

from backend.models.enums import TransactionStatus


@dataclass
class PaymentSession:
    external_id: str
    payment_url: str
    created_at: datetime


@dataclass
class ParsedWebhookEvent:
    event_id: str
    external_id: str
    status: TransactionStatus
    raw_payload: dict[str, Any]


class PaymentGateway(Protocol):
    provider_name: str

    def create_payment(
        self,
        transaction_id: int,
        amount: str,
        currency: str,
        metadata: dict[str, Any] | None = None,
    ) -> PaymentSession:
        ...

    def parse_webhook(self, payload: dict[str, Any]) -> ParsedWebhookEvent:
        ...
