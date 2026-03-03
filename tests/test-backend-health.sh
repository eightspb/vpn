#!/usr/bin/env bash
# =============================================================================
# test-backend-health.sh — тесты health/ready нового FastAPI backend
#
# Проверяет:
#   - Наличие backend структуры и main.py
#   - Импорт и запуск FastAPI app
#   - GET /health → 200, {"status":"ok"}
#   - GET /ready → 200, {"status":"ready"}
#
# Использование:
#   bash tests/test-backend-health.sh
#   BASE_URL=http://localhost:8000 bash tests/test-backend-health.sh  # против уже запущенного
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BACKEND_DIR="${PROJECT_ROOT}/backend"
BASE_URL="${BASE_URL:-http://localhost:8000}"

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); echo -e "\033[0;32m  ✓ $*\033[0m"; }
fail() { FAIL=$((FAIL + 1)); echo -e "\033[0;31m  ✗ $*\033[0m"; }
skip() { SKIP=$((SKIP + 1)); echo -e "\033[1;33m  ⊘ $* (skipped)\033[0m"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   test-backend-health.sh — health/ready нового backend       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Section 1: File existence ────────────────────────────────────────────────

echo "── 1. Наличие файлов ──"

for f in backend/main.py backend/core/config.py backend/api/routes/health.py backend/requirements.txt; do
    if [[ -f "${PROJECT_ROOT}/$f" ]]; then
        pass "$f exists"
    else
        fail "$f NOT found"
    fi
done

# ── Section 2: Python import ───────────────────────────────────────────────────

echo ""
echo "── 2. Импорт backend ──"

PYTHON=""
for cmd in python3 python py; do
    if command -v "$cmd" &>/dev/null; then
        PYTHON="$cmd"
        break
    fi
done

if [[ -z "$PYTHON" ]]; then
    skip "Python not found"
else
    cd "$PROJECT_ROOT"
    # Use backend venv if available (created by scripts/backend/run.sh)
    VENV_PYTHON=""
    if [[ -f "${BACKEND_DIR}/.venv/Scripts/python.exe" ]]; then
        VENV_PYTHON="${BACKEND_DIR}/.venv/Scripts/python.exe"
    elif [[ -f "${BACKEND_DIR}/.venv/bin/python" ]]; then
        VENV_PYTHON="${BACKEND_DIR}/.venv/bin/python"
    fi
    RUN_PYTHON="${VENV_PYTHON:-$PYTHON}"
    # Ensure deps: create venv + install only if fastapi is missing
    if [[ -z "$VENV_PYTHON" ]]; then
        "$PYTHON" -m venv "${BACKEND_DIR}/.venv" 2>/dev/null || true
        if [[ -f "${BACKEND_DIR}/.venv/Scripts/python.exe" ]]; then
            RUN_PYTHON="${BACKEND_DIR}/.venv/Scripts/python.exe"
        elif [[ -f "${BACKEND_DIR}/.venv/bin/python" ]]; then
            RUN_PYTHON="${BACKEND_DIR}/.venv/bin/python"
        fi
    fi

    if ! "$RUN_PYTHON" -c "import fastapi, uvicorn, pydantic_settings" >/dev/null 2>&1; then
        fail "Missing backend deps in ${RUN_PYTHON} (install: pip install -r backend/requirements.txt)"
    fi
    if "$RUN_PYTHON" -c "
import sys
sys.path.insert(0, '.')
from backend.main import app
assert app is not None
print('ok')
" 2>/dev/null; then
        pass "backend.main.app imports"
    else
        fail "backend.main.app import failed (run: bash scripts/backend/run.sh)"
    fi
fi

# ── Section 3: HTTP health/ready ──────────────────────────────────────────────

echo ""
echo "── 3. Health endpoints ──"

if command -v curl &>/dev/null; then
    # Check if server is already running
    if curl -sf "${BASE_URL}/health" &>/dev/null; then
        RES=$(curl -sf "${BASE_URL}/health")
        if echo "$RES" | grep -q '"status"' && echo "$RES" | grep -q '"ok"'; then
            pass "GET /health → 200, status=ok"
        else
            fail "GET /health — unexpected response: $RES"
        fi

        RES=$(curl -sf "${BASE_URL}/ready")
        if echo "$RES" | grep -q '"status"' && echo "$RES" | grep -q '"ready"'; then
            pass "GET /ready → 200, status=ready"
        else
            fail "GET /ready — unexpected response: $RES"
        fi
    else
        # Start server in background, run tests, kill
        cd "$PROJECT_ROOT"
        RUN_PY=""
        [[ -f "${BACKEND_DIR}/.venv/Scripts/python.exe" ]] && RUN_PY="${BACKEND_DIR}/.venv/Scripts/python.exe"
        [[ -z "$RUN_PY" && -f "${BACKEND_DIR}/.venv/bin/python" ]] && RUN_PY="${BACKEND_DIR}/.venv/bin/python"
        [[ -z "$RUN_PY" ]] && RUN_PY="$PYTHON"
        if [[ -z "$PYTHON" ]]; then
            skip "Python not found — cannot start server"
        else
            if ! "$RUN_PY" -c "import fastapi, uvicorn, pydantic_settings" >/dev/null 2>&1; then
                fail "Missing backend deps in ${RUN_PY}"
                exit 1
            fi
            # Start uvicorn in background
            "$RUN_PY" -m uvicorn backend.main:app --host 127.0.0.1 --port 18000 &
            UVICORN_PID=$!
            trap "kill $UVICORN_PID 2>/dev/null || true" EXIT
            sleep 2
            # Wait for server
            for i in {1..60}; do
                if curl -sf "http://127.0.0.1:18000/health" &>/dev/null; then
                    break
                fi
                sleep 0.5
            done
            if curl -sf "http://127.0.0.1:18000/health" &>/dev/null; then
                RES=$(curl -sf "http://127.0.0.1:18000/health")
                if echo "$RES" | grep -q '"status"' && echo "$RES" | grep -q '"ok"'; then
                    pass "GET /health → 200, status=ok"
                else
                    fail "GET /health — unexpected: $RES"
                fi
                RES=$(curl -sf "http://127.0.0.1:18000/ready")
                if echo "$RES" | grep -q '"status"' && echo "$RES" | grep -q '"ready"'; then
                    pass "GET /ready → 200, status=ready"
                else
                    fail "GET /ready — unexpected: $RES"
                fi
            else
                if [[ "$RUN_PY" == *.exe ]]; then
                    skip "Server started via Windows Python, but not reachable from bash (WSL loopback mismatch)"
                else
                    fail "Server did not start in time"
                fi
            fi
        fi
    fi
else
    skip "curl not found — cannot test HTTP"
fi

# ── Summary ──────────────────────────────────────────────────────────────────

echo ""
echo "══════════════════════════════════════════════════════════════"
echo -e "  Results: \033[0;32m$PASS passed\033[0m, \033[0;31m$FAIL failed\033[0m, \033[1;33m$SKIP skipped\033[0m"
echo "══════════════════════════════════════════════════════════════"
echo ""

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
exit 0
