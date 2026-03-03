#!/usr/bin/env bash
# =============================================================================
# test-admin-rbac-smoke.sh — Stage 3 RBAC smoke for UI-relevant scenarios
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
if [[ -f "${BACKEND_DIR}/.venv/Scripts/python.exe" ]] && "${BACKEND_DIR}/.venv/Scripts/python.exe" --version >/dev/null 2>&1; then
    RUN_PYTHON="${BACKEND_DIR}/.venv/Scripts/python.exe"
elif [[ -f "${BACKEND_DIR}/.venv/bin/python" ]] && "${BACKEND_DIR}/.venv/bin/python" --version >/dev/null 2>&1; then
    RUN_PYTHON="${BACKEND_DIR}/.venv/bin/python"
fi

"$RUN_PYTHON" - <<'PY'
import os
from datetime import datetime
from pathlib import Path

from fastapi.testclient import TestClient

project_root = Path.cwd()
db_path = project_root / "vpn-output" / "admin-rbac-test.sqlite3"
output_dir = project_root / "vpn-output" / "test-artifacts-admin-rbac"
if db_path.exists():
    db_path.unlink()
if output_dir.exists():
    for conf in output_dir.glob("*"):
        conf.unlink(missing_ok=True)
else:
    output_dir.mkdir(parents=True, exist_ok=True)

os.environ["DATABASE_URL"] = f"sqlite+pysqlite:///{db_path.as_posix()}"
os.environ["APP_ENV"] = "development"
os.environ["BOT_OUTBOUND_ENABLED"] = "false"
os.environ["VPN_OUTPUT_DIR"] = output_dir.as_posix()

from backend.core.config import get_settings
import backend.db.session as db_session_module

get_settings.cache_clear()
db_session_module.engine = None
db_session_module.SessionLocal = None

from backend.db.session import Base, get_engine, get_session
from backend.models import PeerDevice, RoleEnum, Setting, User

Base.metadata.create_all(bind=get_engine())

with get_session() as session:
    for username, role in [
        ("owner", RoleEnum.OWNER),
        ("admin", RoleEnum.ADMIN),
        ("operator", RoleEnum.OPERATOR),
        ("readonly", RoleEnum.READONLY),
    ]:
        session.add(User(username=username, password_hash="pass12345", role=role))

    session.add(
        PeerDevice(
            name="peer-base",
            ip="10.9.0.3",
            type="phone",
            status="active",
            mode="full",
            config_file=str(project_root / "vpn-output" / "peer-base.conf"),
            created_at=datetime.utcnow(),
            updated_at=datetime.utcnow(),
            config_version=1,
            config_download_count=0,
        )
    )
    session.add(Setting(key="DNS", value="10.8.0.2"))

from backend.main import app


def login_as(username: str) -> TestClient:
    client = TestClient(app)
    resp = client.post("/api/v1/admin/auth/login", json={"username": username, "password": "pass12345"})
    assert resp.status_code == 200, f"login failed for {username}: {resp.text}"
    return client


readonly = login_as("readonly")
assert readonly.get("/api/v1/admin/peers").status_code == 200
assert readonly.get("/api/v1/admin/settings").status_code == 200
assert readonly.put("/api/v1/admin/settings", json={"items": {"DNS": "1.1.1.1"}}).status_code == 403
assert readonly.post("/api/v1/admin/peers", json={"name": "r-fail", "type": "phone"}).status_code == 403

operator = login_as("operator")
assert operator.get("/api/v1/admin/peers").status_code == 200
assert operator.post("/api/v1/admin/peers", json={"name": "op-peer", "type": "phone"}).status_code == 200
assert operator.put("/api/v1/admin/settings", json={"items": {"DNS": "9.9.9.9"}}).status_code == 403

admin = login_as("admin")
assert admin.put("/api/v1/admin/settings", json={"items": {"DNS": "1.1.1.1"}}).status_code == 200
assert admin.post("/api/v1/admin/peers", json={"name": "admin-peer", "type": "phone"}).status_code == 200

owner = login_as("owner")
users = owner.get("/api/v1/admin/users")
assert users.status_code == 200
readonly_id = next(item["id"] for item in users.json()["items"] if item["username"] == "readonly")
upd = owner.put(f"/api/v1/admin/users/{readonly_id}", json={"role": "operator"})
assert upd.status_code == 200, upd.text

for conf in output_dir.glob("*"):
    conf.unlink(missing_ok=True)
output_dir.rmdir()

print("OK: Stage 3 RBAC smoke passed")
PY
