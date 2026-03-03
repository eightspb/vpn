#!/usr/bin/env bash
# =============================================================================
# test-bot-happy-path.sh — happy path для Telegram Bot MVP
#
# Проверяет сценарий:
# /start -> Тарифы -> Купить <offer> -> confirm -> активная подписка
# и наличие audit-событий.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="${PROJECT_ROOT}/backend"
TEST_DB="${PROJECT_ROOT}/vpn-output/bot-test.sqlite3"

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
from datetime import datetime
from decimal import Decimal
from pathlib import Path

from fastapi.testclient import TestClient
from sqlalchemy import select

project_root = Path.cwd()
db_path = project_root / "vpn-output" / "bot-test.sqlite3"
if db_path.exists():
    db_path.unlink()

os.environ["DATABASE_URL"] = f"sqlite+pysqlite:///{db_path.as_posix()}"
os.environ["TELEGRAM_WEBHOOK_SECRET_TOKEN"] = "tg-secret"
os.environ["BOT_INTERNAL_API_TOKEN"] = "internal-token"
os.environ["BOT_OUTBOUND_ENABLED"] = "false"

from backend.core.config import get_settings
import backend.db.session as db_session_module

get_settings.cache_clear()
db_session_module.engine = None
db_session_module.SessionLocal = None

from backend.db.session import Base, get_engine, get_session
from backend.models import Plan, PlanKind, PlanOffer, Subscription, Transaction, TransactionStatus, AuditLog, User
from backend.models.telegram_profile import TelegramProfile

_ = User, TelegramProfile  # keep imported for metadata registration
Base.metadata.create_all(bind=get_engine())

with get_session() as session:
    plan = Plan(name="MVP UNLIMITED", kind=PlanKind.UNLIMITED, description="test")
    session.add(plan)
    session.flush()
    session.add(PlanOffer(plan_id=plan.id, duration_days=30, price=Decimal("199.00"), currency="RUB"))

from backend.bot.main import app

client = TestClient(app)

start_payload = {
    "update_id": 1,
    "message": {
        "message_id": 1,
        "date": int(datetime.utcnow().timestamp()),
        "chat": {"id": 10001, "type": "private"},
        "from": {"id": 900001, "is_bot": False, "first_name": "Ivan", "username": "ivan"},
        "text": "/start",
    },
}
resp = client.post(
    "/webhook/telegram",
    json=start_payload,
    headers={"X-Telegram-Bot-Api-Secret-Token": "tg-secret"},
)
assert resp.status_code == 200, resp.text

tariff_payload = {
    "update_id": 2,
    "message": {**start_payload["message"], "message_id": 2, "text": "Тарифы"},
}
resp = client.post(
    "/webhook/telegram",
    json=tariff_payload,
    headers={"X-Telegram-Bot-Api-Secret-Token": "tg-secret"},
)
assert resp.status_code == 200, resp.text

buy_payload = {
    "update_id": 3,
    "message": {**start_payload["message"], "message_id": 3, "text": "Купить 1"},
}
resp = client.post(
    "/webhook/telegram",
    json=buy_payload,
    headers={"X-Telegram-Bot-Api-Secret-Token": "tg-secret"},
)
assert resp.status_code == 200, resp.text

with get_session() as session:
    tx = session.scalar(select(Transaction).order_by(Transaction.id.desc()))
    assert tx is not None
    assert tx.status == TransactionStatus.PENDING
    external_id = tx.external_id

confirm_resp = client.post(f"/payments/test/confirm/{external_id}?token=internal-token")
assert confirm_resp.status_code == 200, confirm_resp.text

overview_resp = client.get("/admin/bot/overview?token=internal-token")
assert overview_resp.status_code == 200, overview_resp.text
overview = overview_resp.json()
assert overview["stats"]["telegram_users_total"] >= 1

activity_resp = client.get("/admin/bot/activity?token=internal-token&limit=20")
assert activity_resp.status_code == 200, activity_resp.text
assert isinstance(activity_resp.json().get("items"), list)

settings_put_resp = client.put(
    "/admin/bot/settings?token=internal-token",
    json={
        "BOT_ENABLED": "false",
        "BOT_SUPPORT_CONTACT": "@qa_support",
        "BOT_MAINTENANCE_TEXT": "maintenance",
    },
)
assert settings_put_resp.status_code == 200, settings_put_resp.text
settings_get_resp = client.get("/admin/bot/settings?token=internal-token")
assert settings_get_resp.status_code == 200, settings_get_resp.text
assert settings_get_resp.json()["items"]["BOT_ENABLED"] == "false"

with get_session() as session:
    subscription = session.scalar(select(Subscription).order_by(Subscription.id.desc()))
    assert subscription is not None
    assert subscription.status.value == "active"
    tx = session.scalar(select(Transaction).order_by(Transaction.id.desc()))
    assert tx is not None and tx.status == TransactionStatus.COMPLETED

    actions = set(session.scalars(select(AuditLog.action)).all())
    required = {"registration", "payment_created", "payment_confirmed", "subscription_activated", "bot_settings_updated"}
    missing = required - actions
    assert not missing, f"missing audit actions: {missing}"

print("OK: Telegram bot happy path passed")
PY
