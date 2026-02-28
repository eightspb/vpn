#!/usr/bin/env bash
# =============================================================================
# test-admin.sh — статические тесты VPN Admin Panel
#
# Проверяет наличие файлов, синтаксис, структуру кода, зависимости.
# Не требует запуска сервера.
#
# Использование:
#   bash tests/test-admin.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ADMIN_DIR="${PROJECT_ROOT}/scripts/admin"
ADMIN_SCRIPT="${ADMIN_DIR}/admin-server.py"
ADMIN_HTML="${ADMIN_DIR}/admin.html"
REQUIREMENTS="${ADMIN_DIR}/requirements.txt"
DEPLOY_SCRIPT="${PROJECT_ROOT}/scripts/deploy/deploy-admin.sh"

PASS=0
FAIL=0
SKIP=0

pass() { ((PASS++)); echo -e "\033[0;32m  ✓ $*\033[0m"; }
fail() { ((FAIL++)); echo -e "\033[0;31m  ✗ $*\033[0m"; }
skip() { ((SKIP++)); echo -e "\033[1;33m  ⊘ $* (skipped)\033[0m"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   test-admin.sh — статические тесты Admin Panel              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── 1. Наличие файлов ────────────────────────────────────────────────────────

echo "── 1. Наличие файлов ──"

for f in "$ADMIN_SCRIPT" "$ADMIN_HTML" "$REQUIREMENTS" "$DEPLOY_SCRIPT"; do
    name="$(basename "$f")"
    if [[ -f "$f" ]]; then
        size="$(wc -c < "$f")"
        if [[ "$size" -gt 100 ]]; then
            pass "$name exists (${size} bytes)"
        else
            fail "$name exists but too small (${size} bytes)"
        fi
    else
        fail "$name NOT found at $f"
    fi
done

# ── 2. Python syntax check ──────────────────────────────────────────────────

echo ""
echo "── 2. Python syntax check ──"

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
    if "$PYTHON" -c "import ast; ast.parse(open(r'$ADMIN_SCRIPT', encoding='utf-8').read())" 2>/dev/null; then
        pass "admin-server.py syntax valid (ast.parse)"
    else
        fail "admin-server.py has syntax errors"
    fi
fi

# ── 3. Bash syntax check ─────────────────────────────────────────────────────

echo ""
echo "── 3. Bash syntax check ──"

if bash -n "$DEPLOY_SCRIPT" 2>/dev/null; then
    pass "deploy-admin.sh syntax valid (bash -n)"
else
    fail "deploy-admin.sh has syntax errors"
fi

# ── 4. HTML structure check ──────────────────────────────────────────────────

echo ""
echo "── 4. HTML structure check ──"

check_html() {
    local desc="$1" pattern="$2"
    if grep -qi "$pattern" "$ADMIN_HTML" 2>/dev/null; then
        pass "HTML: $desc"
    else
        fail "HTML: $desc (missing: $pattern)"
    fi
}

check_html "DOCTYPE"        "<!DOCTYPE"
check_html "<html> tag"     "<html"
check_html "<head> tag"     "<head"
check_html "<body> tag"     "<body"
check_html "CSS variables"  "--bg-primary"
check_html "Theme toggle"   "theme"
check_html "Login form"     "login"
check_html "Peers table"    "peers"
check_html "Settings page"  "settings"
check_html "Audit log"      "audit"
check_html "API calls"      "/api/"
check_html "JWT token"      "token"
check_html "QR code"        "qr"
check_html "Modal"          "modal"
check_html "Live peers table" "WireGuard peers (live)"

# ── 5. Dependencies check ────────────────────────────────────────────────────

echo ""
echo "── 5. Dependencies (requirements.txt) ──"

for dep in flask flask-cors flask-socketio PyJWT bcrypt paramiko qrcode python-dotenv; do
    if grep -qi "$dep" "$REQUIREMENTS" 2>/dev/null; then
        pass "Dependency: $dep"
    else
        fail "Missing dependency: $dep"
    fi
done

# ── 6. Backend API endpoints ─────────────────────────────────────────────────

echo ""
echo "── 6. Backend API endpoints ──"

check_py() {
    local desc="$1" pattern="$2"
    if grep -qE "$pattern" "$ADMIN_SCRIPT" 2>/dev/null; then
        pass "Backend: $desc"
    else
        fail "Backend: $desc (pattern: $pattern)"
    fi
}

check_py "POST /api/auth/login"           "/api/auth/login"
check_py "POST /api/auth/logout"          "/api/auth/logout"
check_py "POST /api/auth/change-password" "/api/auth/change-password"
check_py "GET  /api/auth/me"              "/api/auth/me"
check_py "GET  /api/peers (list)"         "def peers_list"
check_py "POST /api/peers (create)"       "def peers_create"
check_py "POST /api/peers/batch"          "/api/peers/batch"
check_py "GET  /api/peers/<id>"           "def peers_get"
check_py "PUT  /api/peers/<id>"           "def peers_update"
check_py "DELETE /api/peers/<id>"         "def peers_delete"
check_py "POST /api/peers/<id>/disable"   "/disable"
check_py "POST /api/peers/<id>/enable"    "/enable"
check_py "GET  /api/peers/<id>/config"    "/config"
check_py "GET  /api/peers/<id>/qr"        "/qr"
check_py "GET  /api/peers/stats"          "/api/peers/stats"
check_py "GET  /api/monitoring/data"      "/api/monitoring/data"
check_py "GET  /api/monitoring/peers"     "/api/monitoring/peers"
check_py "GET  /api/settings"             "def settings_get"
check_py "PUT  /api/settings"             "def settings_update"
check_py "GET  /api/audit"               "def audit_list"
check_py "GET  /api/health"              "def health"

# ── 7. Backend features ──────────────────────────────────────────────────────

echo ""
echo "── 7. Backend features ──"

check_py "SQLite schema (users)"       "CREATE TABLE.*users"
check_py "SQLite schema (peers)"       "CREATE TABLE.*peers"
check_py "SQLite schema (audit_log)"   "CREATE TABLE.*audit_log"
check_py "SQLite schema (settings)"    "CREATE TABLE.*settings"
check_py "JWT encode"                  "jwt\.encode"
check_py "JWT decode"                  "jwt\.decode"
check_py "bcrypt hashpw"              "bcrypt\.hashpw"
check_py "bcrypt checkpw"             "bcrypt\.checkpw"
check_py "Rate limiting"              "_check_rate_limit"
check_py "Token blacklist"            "_blacklisted_tokens"
check_py "Auth decorator"             "def auth_required"
check_py "Audit logging"              "def audit"
check_py "SSH exec"                   "def ssh_exec"
check_py "Paramiko SSHClient"         "paramiko\.SSHClient"
check_py "IP allocation"              "_allocate_ip"
check_py "Config builder"             "_build_config"
check_py "QR generation"              "_generate_qr_base64"
check_py "peers.json sync"            "sync_peers_to_json"
check_py "peers.json import"          "_import_peers_from_json"
check_py "Default admin"              "_ensure_default_admin"
check_py "Default settings"           "_load_default_settings"
check_py "WebSocket monitor"          "_monitor_loop"
check_py "MTU by device type"         "MTU_BY_TYPE"
check_py "Monitoring peer_ip field"   "peer_ip"
check_py "AllowedIPs IP extraction"   "_extract_peer_ip"

# ── 8. Deploy script structure ────────────────────────────────────────────────

echo ""
echo "── 8. Deploy script structure ──"

check_deploy() {
    local desc="$1" pattern="$2"
    if grep -qE "$pattern" "$DEPLOY_SCRIPT" 2>/dev/null; then
        pass "Deploy: $desc"
    else
        fail "Deploy: $desc (pattern: $pattern)"
    fi
}

check_deploy "Sources lib/common.sh"   "source.*lib/common.sh"
check_deploy "Command: start"          "cmd_start"
check_deploy "Command: stop"           "cmd_stop"
check_deploy "Command: status"         "cmd_status"
check_deploy "Command: setup"          "cmd_setup"
check_deploy "Command: restart"        "cmd_restart"
check_deploy "Command: logs"           "cmd_logs"
check_deploy "PID file handling"       "PID_FILE"
check_deploy "Venv creation"           "venv"
check_deploy "pip install"             "pip install"
check_deploy "nohup background"        "nohup"
check_deploy "Log file"               "LOG_FILE"
check_deploy "Python detection"        "find_python"
check_deploy "Host bind option"        "\-\-host"
check_deploy "Process discovery fallback" "find_running_admin_pid"
check_deploy "Port ownership detection" "get_listener_pid_by_port"
check_deploy "Graceful stop helper"    "stop_pid_gracefully"

# ── 9. Security checks ───────────────────────────────────────────────────────

echo ""
echo "── 9. Security features ──"

check_py "Rate limit: 5 attempts"     "LOGIN_MAX_ATTEMPTS.*=.*5"
check_py "Rate limit: 60s window"     "LOGIN_WINDOW_SEC.*=.*60"
check_py "bcrypt rounds=12"           "rounds=12"
check_py "JWT TTL configurable"       "JWT_TTL_HOURS"
check_py "CORS configuration"         "CORS\("
check_py "Password min length"        "len.*new_pw.*<.*6"
check_py "Config: [Interface]"        "\\[Interface\\]"
check_py "Config: [Peer]"             "\\[Peer\\]"
check_py "Config: PresharedKey"       "PresharedKey"
check_py "Config: AllowedIPs"         "AllowedIPs"
check_py "Junk params"                "Jmin.*Jmax"

# ── 10. Frontend API integration ──────────────────────────────────────────────

echo ""
echo "── 10. Frontend API integration ──"

check_html_api() {
    local desc="$1" pattern="$2"
    if grep -q "$pattern" "$ADMIN_HTML" 2>/dev/null; then
        pass "Frontend: $desc"
    else
        fail "Frontend: $desc (missing: $pattern)"
    fi
}

check_html_api "Auth login call"      "/api/auth/login"
check_html_api "Peers list call"      "/api/peers"
check_html_api "Settings call"        "/api/settings"
check_html_api "Audit call"           "/api/audit"
check_html_api "Health check"         "/api/health"
check_html_api "Cookie session (credentials include)" "credentials: 'include'"
check_html_api "Peer speed tooltip" "peer-speed-tooltip"
check_html_api "Peers speed column" ">Speed<"

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
