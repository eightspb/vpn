"""Временный test payment provider для MVP."""

from dataclasses import dataclass
from datetime import datetime
import secrets


@dataclass
class PaymentSession:
    external_id: str
    payment_url: str
    created_at: datetime


class TestPaymentProvider:
    """Генерирует фейковую платёжную сессию для локального MVP."""

    provider_name = "test"

    def create_payment(self, transaction_id: int, amount: str, currency: str) -> PaymentSession:
        suffix = secrets.token_hex(4)
        external_id = f"testpay_{transaction_id}_{suffix}"
        return PaymentSession(
            external_id=external_id,
            payment_url=f"https://test-payments.local/pay/{external_id}?amount={amount}&currency={currency}",
            created_at=datetime.utcnow(),
        )
