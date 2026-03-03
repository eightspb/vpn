#!/usr/bin/env bash
# =============================================================================
# test-admin-v1-happy-path.sh — Stage 3 Admin API happy path
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="${PROJECT_ROOT}/backend"
TEST_DB="${PROJECT_ROOT}/vpn-output/admin-v1-test.sqlite3"

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

from fastapi.testclient import TestClient

project_root = Path.cwd()
db_path = project_root / "vpn-output" / "admin-v1-test.sqlite3"
if db_path.exists():
    db_path.unlink()

os.environ["DATABASE_URL"] = f"sqlite+pysqlite:///{db_path.as_posix()}"
os.environ["APP_ENV"] = "development"
os.environ["BOT_OUTBOUND_ENABLED"] = "false"
os.environ["LEGACY_ADMIN_BASE_URL"] = "http://127.0.0.1:65535"

from backend.core.config import get_settings
import backend.db.session as db_session_module

get_settings.cache_clear()
db_session_module.engine = None
db_session_module.SessionLocal = None

from backend.db.session import Base, get_engine, get_session
from backend.models import (
    Plan,
    PlanKind,
    PlanOffer,
    RoleEnum,
    Setting,
    Subscription,
    SubscriptionStatus,
    Transaction,
    User,
)

Base.metadata.create_all(bind=get_engine())

with get_session() as session:
    admin = User(username="admin", password_hash="adminpass", role=RoleEnum.OWNER)
    session.add(admin)
    session.flush()

    user = User(username="customer", password_hash="noop", role=RoleEnum.USER)
    session.add(user)
    session.flush()

    plan = Plan(name="Base", kind=PlanKind.UNLIMITED, description="desc")
    session.add(plan)
    session.flush()

    offer = PlanOffer(plan_id=plan.id, duration_days=30, price=Decimal("199.00"), currency="RUB")
    session.add(offer)
    session.flush()

    sub = Subscription(
        user_id=user.id,
        plan_offer_id=offer.id,
        status=SubscriptionStatus.PENDING,
        started_at=datetime.utcnow(),
        expires_at=datetime.utcnow() + timedelta(days=30),
    )
    session.add(sub)
    session.flush()

    tx = Transaction(
        subscription_id=sub.id,
        amount=Decimal("199.00"),
        currency="RUB",
        provider="test",
        external_id="tx-1",
        status="pending",
    )
    session.add(tx)
    session.add(Setting(key="DNS", value="10.8.0.2"))

from backend.main import app

client = TestClient(app)

login = client.post("/api/v1/admin/auth/login", json={"username": "admin", "password": "adminpass"})
assert login.status_code == 200, login.text
assert login.cookies.get("admin_sid"), "admin_sid cookie expected"

me = client.get("/api/v1/admin/auth/me")
assert me.status_code == 200, me.text
assert me.json()["role"] == "owner"

users = client.get("/api/v1/admin/users")
assert users.status_code == 200, users.text
assert users.json()["total"] >= 2

plans = client.post(
    "/api/v1/admin/plans",
    json={"name": "Traffic", "kind": "TRAFFIC", "traffic_limit_mb": 10240},
)
assert plans.status_code == 200, plans.text
plan_id = plans.json()["id"]

offer = client.post(
    "/api/v1/admin/offers",
    json={"plan_id": plan_id, "duration_days": 90, "price": "499.00", "currency": "rub"},
)
assert offer.status_code == 200, offer.text
assert offer.json()["currency"] == "RUB"

subs = client.get("/api/v1/admin/subscriptions")
assert subs.status_code == 200, subs.text
assert subs.json()["total"] >= 1

sub_id = subs.json()["items"][0]["id"]
sub_upd = client.put(
    f"/api/v1/admin/subscriptions/{sub_id}",
    json={"status": "active"},
)
assert sub_upd.status_code == 200, sub_upd.text
assert sub_upd.json()["status"] == "active"

trs = client.get("/api/v1/admin/transactions")
assert trs.status_code == 200, trs.text
assert trs.json()["total"] >= 1

settings = client.put("/api/v1/admin/settings", json={"items": {"DNS": "1.1.1.1"}})
assert settings.status_code == 200, settings.text
assert settings.json()["items"]["DNS"] == "1.1.1.1"

peer_create = client.post(
    "/api/v1/admin/peers",
    json={"name": "phone-001", "type": "phone", "group_name": "qa", "traffic_limit_mb": 1024},
)
assert peer_create.status_code == 200, peer_create.text
peer_id = peer_create.json()["id"]

peer_list = client.get("/api/v1/admin/peers")
assert peer_list.status_code == 200, peer_list.text
assert any(item.get("id") == peer_id for item in peer_list.json())

peer_cfg = client.get(f"/api/v1/admin/peers/{peer_id}/config")
assert peer_cfg.status_code == 200, peer_cfg.text
assert "Address =" in peer_cfg.text

mon_data = client.get("/api/v1/admin/monitoring/data")
assert mon_data.status_code == 200, mon_data.text

mon_peers = client.get("/api/v1/admin/monitoring/peers")
assert mon_peers.status_code == 200, mon_peers.text
assert isinstance(mon_peers.json(), list)

compat_me = client.get("/api/auth/me")
assert compat_me.status_code == 200, compat_me.text

compat_settings = client.put("/api/settings", json={"Jc": "5"})
assert compat_settings.status_code == 200, compat_settings.text
assert isinstance(compat_settings.json(), dict), compat_settings.text

audit = client.get("/api/v1/admin/audit")
assert audit.status_code == 200, audit.text
assert audit.json()["total"] >= 1

logout = client.post("/api/v1/admin/auth/logout")
assert logout.status_code == 200, logout.text
post_logout = client.get("/api/v1/admin/auth/me")
assert post_logout.status_code == 401, post_logout.text

print("OK: Stage 3 admin API happy path passed")
PY
