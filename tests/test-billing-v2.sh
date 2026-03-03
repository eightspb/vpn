#!/usr/bin/env bash
# =============================================================================
# test-billing-v2.sh — Stage 4 billing smoke
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="${PROJECT_ROOT}/backend"

PYTHON=""
for cmd in python3 python py; do
    if command -v "$cmd" &>/dev/null; then
        PYTHON="$cmd"
        break
    fi
done

if [[ -z "$PYTHON" ]]; then
    echo "Python not found"
    exit 1
fi

RUN_PYTHON="$PYTHON"
if [[ -f "${BACKEND_DIR}/.venv/Scripts/python.exe" ]]; then
    RUN_PYTHON="${BACKEND_DIR}/.venv/Scripts/python.exe"
elif [[ -f "${BACKEND_DIR}/.venv/bin/python" ]]; then
    RUN_PYTHON="${BACKEND_DIR}/.venv/bin/python"
fi

"$RUN_PYTHON" - <<'PY'
import os
from datetime import datetime, timedelta
from decimal import Decimal
from pathlib import Path

from sqlalchemy import select

project_root = Path.cwd()
db_path = project_root / "vpn-output" / "billing-v2-test.sqlite3"
if db_path.exists():
    db_path.unlink()

os.environ["DATABASE_URL"] = f"sqlite+pysqlite:///{db_path.as_posix()}"
os.environ["BOT_OUTBOUND_ENABLED"] = "false"

from backend.core.config import get_settings
import backend.db.session as db_session_module

get_settings.cache_clear()
db_session_module.engine = None
db_session_module.SessionLocal = None

from backend.db.session import Base, get_engine, get_session
from backend.models import Plan, PlanKind, PlanOffer, Promocode, PromocodeKind, RoleEnum, Transaction, TransactionStatus, User
from backend.services.billing_service import build_billing_service

Base.metadata.create_all(bind=get_engine())
billing = build_billing_service()

with get_session() as session:
    user = User(username="billing-user", password_hash="x", role=RoleEnum.USER)
    session.add(user)
    session.flush()
    plan = Plan(name="Billing", kind=PlanKind.UNLIMITED, description="stage4")
    session.add(plan)
    session.flush()
    offer = PlanOffer(plan_id=plan.id, duration_days=30, price=Decimal("300.00"), currency="RUB")
    session.add(offer)
    session.add(
        Promocode(
            code="SALE50",
            kind=PromocodeKind.PERCENT,
            value=Decimal("50.00"),
            is_active=True,
            usage_limit=5,
            expires_at=datetime.utcnow() + timedelta(days=30),
        )
    )
    session.flush()
    user_id = user.id
    offer_id = offer.id

with get_session() as session:
    checkout = billing.create_checkout(
        session=session,
        user_id=user_id,
        offer_id=offer_id,
        provider="manual",
        promocode_code="sale50",
        trial=False,
        ip_address="127.0.0.1",
    )
    assert checkout.charged_amount == Decimal("150.00")
    tx = session.get(Transaction, checkout.transaction_id)
    assert tx is not None and tx.status == TransactionStatus.PENDING

with get_session() as session:
    result1 = billing.process_webhook(
        session=session,
        provider="manual",
        payload={"invoice_id": checkout.external_id, "callback_id": "cb-1", "state": "paid"},
        ip_address="127.0.0.1",
    )
    assert result1.found and not result1.duplicate

with get_session() as session:
    result2 = billing.process_webhook(
        session=session,
        provider="manual",
        payload={"invoice_id": checkout.external_id, "callback_id": "cb-1", "state": "paid"},
        ip_address="127.0.0.1",
    )
    assert result2.found and result2.duplicate
    tx = session.get(Transaction, checkout.transaction_id)
    assert tx is not None and tx.status == TransactionStatus.COMPLETED

with get_session() as session:
    trial = billing.create_checkout(
        session=session,
        user_id=user_id,
        offer_id=offer_id,
        provider="test",
        trial=True,
        ip_address="127.0.0.1",
    )
    assert trial.is_trial
    assert trial.charged_amount == Decimal("0.00")
    tx = session.get(Transaction, trial.transaction_id)
    assert tx is not None and tx.status == TransactionStatus.COMPLETED

ok = False
with get_session() as session:
    try:
        billing.create_checkout(
            session=session,
            user_id=user_id,
            offer_id=offer_id,
            provider="test",
            trial=True,
            ip_address="127.0.0.1",
        )
    except ValueError:
        ok = True
assert ok, "second trial in cooldown must fail"

print("OK: Stage 4 billing v2 smoke passed")
PY
