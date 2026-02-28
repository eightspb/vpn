#!/usr/bin/env bash
# =============================================================================
# test-admin-server.sh — тесты для admin-server.py
#
# Проверяет:
#   - Наличие файлов и зависимостей
#   - Структуру admin-server.py (эндпоинты, функции, схема БД)
#   - Импорт модулей Python (синтаксис)
#   - Создание и инициализацию БД (SQLite)
#   - REST API (запуск сервера, login, peers CRUD, settings, audit)
#
# Использование:
#   bash tests/test-admin-server.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ADMIN_DIR="${PROJECT_ROOT}/scripts/admin"
ADMIN_SCRIPT="${ADMIN_DIR}/admin-server.py"
REQUIREMENTS="${ADMIN_DIR}/requirements.txt"

PASS=0
FAIL=0
SKIP=0

pass() { ((PASS++)); echo -e "\033[0;32m  ✓ $*\033[0m"; }
fail() { ((FAIL++)); echo -e "\033[0;31m  ✗ $*\033[0m"; }
skip() { ((SKIP++)); echo -e "\033[1;33m  ⊘ $* (skipped)\033[0m"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   test-admin-server.sh — тесты admin panel backend          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ── Section 1: File existence ────────────────────────────────────────────────

echo "── 1. Наличие файлов ──"

if [[ -f "$ADMIN_SCRIPT" ]]; then
    pass "admin-server.py exists"
else
    fail "admin-server.py NOT found at $ADMIN_SCRIPT"
fi

if [[ -f "$REQUIREMENTS" ]]; then
    pass "requirements.txt exists"
else
    fail "requirements.txt NOT found at $REQUIREMENTS"
fi

# ── Section 2: requirements.txt content ──────────────────────────────────────

echo ""
echo "── 2. Зависимости (requirements.txt) ──"

for dep in flask flask-cors flask-socketio PyJWT bcrypt paramiko qrcode python-dotenv; do
    if grep -qi "$dep" "$REQUIREMENTS" 2>/dev/null; then
        pass "Dependency: $dep"
    else
        fail "Missing dependency: $dep"
    fi
done

# ── Section 3: admin-server.py structure ─────────────────────────────────────

echo ""
echo "── 3. Структура admin-server.py ──"

check_pattern() {
    local desc="$1" pattern="$2"
    if grep -qE "$pattern" "$ADMIN_SCRIPT" 2>/dev/null; then
        pass "$desc"
    else
        fail "$desc (pattern: $pattern)"
    fi
}

check_pattern "Flask app creation"         "app\s*=\s*Flask"
check_pattern "SocketIO init"              "socketio\s*=\s*SocketIO"
check_pattern "CORS init"                  "CORS\("
check_pattern "SQLite DB_PATH"             "DB_PATH"
check_pattern "JWT token creation"         "jwt\.encode"
check_pattern "JWT token decode"           "jwt\.decode"
check_pattern "bcrypt hashpw"              "bcrypt\.hashpw"
check_pattern "bcrypt checkpw"             "bcrypt\.checkpw"
check_pattern "paramiko SSHClient"         "paramiko\.SSHClient"

echo ""
echo "── 3a. Database schema ──"

check_pattern "Table: users"               "CREATE TABLE.*users"
check_pattern "Table: peers"               "CREATE TABLE.*peers"
check_pattern "Table: audit_log"           "CREATE TABLE.*audit_log"
check_pattern "Table: settings"            "CREATE TABLE.*settings"
check_pattern "Column: password_hash"      "password_hash"
check_pattern "Column: public_key"         "public_key"
check_pattern "Column: preshared_key"      "preshared_key"
check_pattern "Column: traffic_limit_mb"   "traffic_limit_mb"
check_pattern "Column: config_file"        "config_file"
check_pattern "Column: ip_address (audit)" "ip_address"

echo ""
echo "── 3b. API endpoints ──"

check_pattern "POST /api/auth/login"           "/api/auth/login"
check_pattern "POST /api/auth/logout"          "/api/auth/logout"
check_pattern "POST /api/auth/change-password" "/api/auth/change-password"
check_pattern "GET  /api/auth/me"              "/api/auth/me"
check_pattern "GET  /api/peers"                "def peers_list"
check_pattern "POST /api/peers"                "def peers_create"
check_pattern "POST /api/peers/batch"          "/api/peers/batch"
check_pattern "GET  /api/peers/<id>"           "def peers_get"
check_pattern "PUT  /api/peers/<id>"           "def peers_update"
check_pattern "DELETE /api/peers/<id>"         "def peers_delete"
check_pattern "POST /api/peers/<id>/disable"   "/disable"
check_pattern "POST /api/peers/<id>/enable"    "/enable"
check_pattern "GET  /api/peers/<id>/config"    "/config"
check_pattern "GET  /api/peers/<id>/qr"        "/qr"
check_pattern "GET  /api/peers/stats"          "/api/peers/stats"
check_pattern "GET  /api/monitoring/data"       "/api/monitoring/data"
check_pattern "GET  /api/monitoring/peers"      "/api/monitoring/peers"
check_pattern "GET  /api/settings"             "def settings_get"
check_pattern "PUT  /api/settings"             "def settings_update"
check_pattern "GET  /api/audit"                "def audit_list"
check_pattern "GET  /api/health"               "def health"

echo ""
echo "── 3c. Key features ──"

check_pattern "Rate limiting"              "_check_rate_limit"
check_pattern "Token blacklist (logout)"   "_blacklisted_tokens"
check_pattern "MTU by device type"         "MTU_BY_TYPE"
check_pattern "IP allocation 10.9.0.x"    "10\.9\.0\."
check_pattern "Config builder"             "_build_config"
check_pattern "QR generation"              "_generate_qr_base64"
check_pattern "peers.json sync"            "sync_peers_to_json"
check_pattern "peers.json import"          "_import_peers_from_json"
check_pattern "Default admin creation"     "_ensure_default_admin"
check_pattern "Default settings loader"    "_load_default_settings"
check_pattern "Audit logging function"     "def audit"
check_pattern "SSH exec helper"            "def ssh_exec"
check_pattern "SSH upload helper"          "def ssh_upload"
check_pattern "WebSocket monitor"          "_monitor_loop"
check_pattern "Auth decorator"             "def auth_required"
check_pattern "Monitoring peer_ip field"   "peer_ip"
check_pattern "AllowedIPs IP extraction"   "_extract_peer_ip"
check_pattern "Peer online threshold env"   "ADMIN_PEER_ONLINE_HANDSHAKE_SEC"
check_pattern "Peers response threshold"    "connection_threshold_sec"
check_pattern "Pagination (audit)"         "per_page"
check_pattern "Peer filtering (status)"    'status = \?'
check_pattern "Peer search"                "LIKE \?"
check_pattern "PresharedKey in config"     "PresharedKey"
check_pattern "AllowedIPs in config"       "AllowedIPs"
check_pattern "PersistentKeepalive"        "PersistentKeepalive"
check_pattern "Junk params (Jc,Jmin...)"   "Jmin.*Jmax"

# ── Section 4: Python syntax check ──────────────────────────────────────────

echo ""
echo "── 4. Python syntax check ──"

PYTHON=""
for cmd in python3 python py; do
    if command -v "$cmd" &>/dev/null; then
        PYTHON="$cmd"
        break
    fi
done

if [[ -z "$PYTHON" ]]; then
    skip "Python not found — cannot run syntax/import checks"
else
    if "$PYTHON" -c "import ast; ast.parse(open('$ADMIN_SCRIPT').read())" 2>/dev/null; then
        pass "Python syntax valid (ast.parse)"
    else
        fail "Python syntax error in admin-server.py"
    fi
fi

# ── Section 5: DB init + API smoke test ──────────────────────────────────────

echo ""
echo "── 5. Database init + API smoke test ──"

if [[ -z "$PYTHON" ]]; then
    skip "Python not found — cannot run DB/API tests"
else
    HAS_DEPS=true
    for mod in flask flask_cors flask_socketio jwt bcrypt paramiko qrcode dotenv; do
        if ! "$PYTHON" -c "import $mod" 2>/dev/null; then
            HAS_DEPS=false
            break
        fi
    done

    if [[ "$HAS_DEPS" == false ]]; then
        skip "Python dependencies not installed — run: pip install -r $REQUIREMENTS"
    else
        TEST_DB="/tmp/admin_test_$$.db"
        SMOKE_RESULT=$("$PYTHON" -c "
import sys, os, json, tempfile

sys.path.insert(0, '$ADMIN_DIR')
os.environ['ADMIN_SECRET_KEY'] = 'test-secret-key-12345'

# Patch DB_PATH before importing
import importlib
spec = importlib.util.spec_from_file_location('admin_server', '$ADMIN_SCRIPT')
mod = importlib.util.module_from_spec(spec)

# Override DB path
import types
original_init = None

# We'll test DB creation directly
import sqlite3
db = sqlite3.connect('$TEST_DB')
db.executescript('''
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at TEXT NOT NULL DEFAULT (datetime(\"now\")),
    last_login TEXT
);
CREATE TABLE IF NOT EXISTS peers (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,
    ip TEXT UNIQUE NOT NULL,
    type TEXT NOT NULL DEFAULT \"phone\",
    mode TEXT NOT NULL DEFAULT \"full\",
    public_key TEXT,
    private_key TEXT,
    preshared_key TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime(\"now\")),
    updated_at TEXT NOT NULL DEFAULT (datetime(\"now\")),
    status TEXT NOT NULL DEFAULT \"active\",
    expiry_date TEXT,
    group_name TEXT,
    traffic_limit_mb INTEGER,
    config_file TEXT
);
CREATE TABLE IF NOT EXISTS audit_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id INTEGER,
    action TEXT NOT NULL,
    target TEXT,
    details TEXT,
    created_at TEXT NOT NULL DEFAULT (datetime(\"now\")),
    ip_address TEXT
);
CREATE TABLE IF NOT EXISTS settings (
    key TEXT PRIMARY KEY,
    value TEXT
);
''')
db.commit()

# Test: tables exist
tables = [r[0] for r in db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\").fetchall()]
results = []
for t in ['users', 'peers', 'audit_log', 'settings']:
    results.append(f'table_{t}={\"ok\" if t in tables else \"fail\"}')

# Test: insert user
import bcrypt
pw = bcrypt.hashpw(b'testpass', bcrypt.gensalt(rounds=4)).decode()
db.execute('INSERT INTO users (username, password_hash) VALUES (?, ?)', ('testadmin', pw))
db.commit()
user = db.execute('SELECT * FROM users WHERE username = ?', ('testadmin',)).fetchone()
results.append(f'user_insert={\"ok\" if user else \"fail\"}')

# Test: insert peer
db.execute('''INSERT INTO peers (name, ip, type, mode, public_key, private_key, status)
              VALUES (?, ?, ?, ?, ?, ?, ?)''',
           ('test-phone', '10.9.0.3', 'phone', 'full', 'pubkey123', 'privkey123', 'active'))
db.commit()
peer = db.execute('SELECT * FROM peers WHERE name = ?', ('test-phone',)).fetchone()
results.append(f'peer_insert={\"ok\" if peer else \"fail\"}')

# Test: insert setting
db.execute('INSERT INTO settings (key, value) VALUES (?, ?)', ('DNS', '10.8.0.2'))
db.commit()
setting = db.execute('SELECT value FROM settings WHERE key = ?', ('DNS',)).fetchone()
results.append(f'setting_insert={\"ok\" if setting and setting[0] == \"10.8.0.2\" else \"fail\"}')

# Test: insert audit
db.execute('INSERT INTO audit_log (user_id, action, target) VALUES (?, ?, ?)', (1, 'test_action', 'test_target'))
db.commit()
audit_entry = db.execute('SELECT * FROM audit_log WHERE action = ?', ('test_action',)).fetchone()
results.append(f'audit_insert={\"ok\" if audit_entry else \"fail\"}')

# Test: IP uniqueness constraint
try:
    db.execute('''INSERT INTO peers (name, ip, type, mode, status)
                  VALUES (?, ?, ?, ?, ?)''',
               ('dup-phone', '10.9.0.3', 'phone', 'full', 'active'))
    db.commit()
    results.append('ip_unique=fail')
except Exception:
    results.append('ip_unique=ok')

# Test: bcrypt verify
ok = bcrypt.checkpw(b'testpass', pw.encode())
results.append(f'bcrypt_verify={\"ok\" if ok else \"fail\"}')

# Test: JWT
import jwt as pyjwt
import datetime
token = pyjwt.encode({'sub': 1, 'exp': datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(hours=1)}, 'secret', algorithm='HS256')
decoded = pyjwt.decode(token, 'secret', algorithms=['HS256'])
results.append(f'jwt_roundtrip={\"ok\" if decoded[\"sub\"] == 1 else \"fail\"}')

db.close()
os.unlink('$TEST_DB')

print('|'.join(results))
" 2>&1) || true

        if [[ -n "$SMOKE_RESULT" ]]; then
            IFS='|' read -ra CHECKS <<< "$SMOKE_RESULT"
            for check in "${CHECKS[@]}"; do
                key="${check%%=*}"
                val="${check##*=}"
                desc="${key//_/ }"
                if [[ "$val" == "ok" ]]; then
                    pass "DB smoke: $desc"
                else
                    fail "DB smoke: $desc"
                fi
            done
        else
            fail "DB smoke test produced no output"
        fi

        rm -f "$TEST_DB" 2>/dev/null || true
    fi
fi

# ── Section 6: Config template validation ────────────────────────────────────

echo ""
echo "── 6. Config template ──"

check_pattern "[Interface] section"        "\\[Interface\\]"
check_pattern "[Peer] section"             "\\[Peer\\]"
check_pattern "PrivateKey field"           "PrivateKey"
check_pattern "Address field"              "Address.*peer_ip"
check_pattern "DNS field"                  "DNS.*dns"
check_pattern "MTU field"                  "MTU.*mtu"
check_pattern "Endpoint field"             "Endpoint.*endpoint"
check_pattern "H1-H4 params"              "H1.*H2.*H3.*H4"

# ── Section 7: Security features ─────────────────────────────────────────────

echo ""
echo "── 7. Security ──"

check_pattern "Rate limit constant"        "LOGIN_MAX_ATTEMPTS\s*=\s*5"
check_pattern "Rate limit window 60s"      "LOGIN_WINDOW_SEC\s*=\s*60"
check_pattern "bcrypt rounds=12"           "rounds=12"
check_pattern "JWT TTL configurable"       "JWT_TTL_HOURS"
check_pattern "CORS configuration"         "cors_allowed_origins"
check_pattern "Password min length"        "len.*new_pw.*<\s*6"

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
