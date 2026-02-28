#!/usr/bin/env python3
"""
admin-server.py — Flask REST API backend for AmneziaWG VPN admin panel.

Provides peer management, monitoring, settings, audit logging, and
real-time WebSocket updates.  Stores state in SQLite (admin.db) and
keeps vpn-output/peers.json in sync with the existing CLI tooling.

Usage:
    python admin-server.py                  # dev  — localhost:8081 (no conflict with monitor-web on 8080)
    python admin-server.py --prod           # prod — 0.0.0.0:8443 (HTTPS)
    python admin-server.py --port 9000      # custom port
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import functools
import hashlib
import io
import json
import logging
import os
import re
import secrets
import sqlite3
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

import bcrypt
import jwt
import paramiko
import qrcode
from dotenv import dotenv_values
from flask import Flask, Response, g, jsonify, request, send_from_directory
from flask_cors import CORS
from flask_socketio import SocketIO

# =============================================================================
# Paths
# =============================================================================

SCRIPT_DIR = Path(__file__).resolve().parent
PROJECT_ROOT = SCRIPT_DIR.parent.parent
DB_PATH = SCRIPT_DIR / "admin.db"
ENV_PATH = PROJECT_ROOT / ".env"
KEYS_ENV_PATH = PROJECT_ROOT / "vpn-output" / "keys.env"
PEERS_JSON_PATH = PROJECT_ROOT / "vpn-output" / "peers.json"
MONITOR_DATA_PATH = PROJECT_ROOT / "scripts" / "monitor" / "vpn-output" / "data.json"
# Единая папка конфигов пиров — все .conf файлы хранятся и загружаются отсюда
CONFIGS_DIR = PROJECT_ROOT / "vpn-output"

# =============================================================================
# Logging
# =============================================================================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("admin")

# =============================================================================
# Flask app
# =============================================================================

app = Flask(__name__)
DEFAULT_DEV_CORS_ORIGINS = [
    "http://localhost:8081",
    "http://127.0.0.1:8081",
    "http://localhost:8080",
    "http://127.0.0.1:8080",
]


def _parse_cors_origins(raw: str) -> list[str]:
    """Parse comma-separated CORS origins."""
    origins = [item.strip() for item in (raw or "").split(",")]
    return [o for o in origins if o]


def _resolve_cors_origins(prod: bool) -> list[str]:
    """Return CORS allowlist from env, or safe defaults for dev."""
    raw = (get_env("ADMIN_CORS_ORIGINS") or os.environ.get("ADMIN_CORS_ORIGINS", "")).strip()
    parsed = _parse_cors_origins(raw)
    if parsed:
        return parsed
    return [] if prod else list(DEFAULT_DEV_CORS_ORIGINS)


# In dev we use an ephemeral key if ADMIN_SECRET_KEY is not set.
app.config["SECRET_KEY"] = os.environ.get("ADMIN_SECRET_KEY", "") or secrets.token_hex(32)
app.config["JWT_TTL_HOURS"] = int(os.environ.get("ADMIN_JWT_TTL_HOURS", "24"))

_bootstrap_origins = _parse_cors_origins(os.environ.get("ADMIN_CORS_ORIGINS", "")) or list(DEFAULT_DEV_CORS_ORIGINS)
CORS(app, resources={r"/api/*": {"origins": _bootstrap_origins}}, supports_credentials=True)
socketio = SocketIO(app, cors_allowed_origins=_bootstrap_origins, async_mode="threading")

# =============================================================================
# Rate limiter (in-memory, per IP)
# =============================================================================

_login_attempts: dict[str, list[float]] = {}
_login_lock = threading.Lock()
LOGIN_MAX_ATTEMPTS = 20
LOGIN_WINDOW_SEC = 120


def _clear_rate_limit(ip: str) -> None:
    """Clear rate limit for IP (after successful login)."""
    with _login_lock:
        _login_attempts.pop(ip, None)


def _check_rate_limit(ip: str) -> bool:
    """Return True if request is allowed, False if rate-limited."""
    now = time.time()
    with _login_lock:
        attempts = _login_attempts.setdefault(ip, [])
        attempts[:] = [t for t in attempts if now - t < LOGIN_WINDOW_SEC]
        if len(attempts) >= LOGIN_MAX_ATTEMPTS:
            return False
        attempts.append(now)
    return True


# Invalidated tokens (logout)
_blacklisted_tokens: set[str] = set()

# Server-side sessions: session_id -> JWT (so cookie is short, browser always sends it)
_sessions: dict[str, dict[str, Any]] = {}
_sessions_lock = threading.Lock()
SESSION_COOKIE_NAME = "admin_sid"
SESSION_TTL_SEC = 24 * 3600  # 24h
PEER_ONLINE_HANDSHAKE_SEC = int(os.environ.get("ADMIN_PEER_ONLINE_HANDSHAKE_SEC", "55"))

# =============================================================================
# Environment / config helpers
# =============================================================================


def _read_kv_file(path: Path) -> dict[str, str]:
    """Parse a KEY=VALUE file, stripping quotes and whitespace."""
    result: dict[str, str] = {}
    if not path.is_file():
        return result
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, val = line.partition("=")
        val = val.strip().strip("\"'")
        result[key.strip()] = val
    return result


def load_env() -> dict[str, str]:
    """Merge .env and vpn-output/keys.env into a single dict."""
    env: dict[str, str] = {}
    env.update(_read_kv_file(KEYS_ENV_PATH))
    env.update(_read_kv_file(ENV_PATH))
    env.update(dotenv_values(ENV_PATH))
    return env


_env_cache: dict[str, str] = {}


def get_env(key: str, default: str = "") -> str:
    global _env_cache
    if not _env_cache:
        _env_cache = load_env()
    return _env_cache.get(key, default)


def reload_env() -> None:
    global _env_cache
    _env_cache = load_env()


# =============================================================================
# Database
# =============================================================================

_DB_SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    username    TEXT UNIQUE NOT NULL,
    password_hash TEXT NOT NULL,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    last_login  TEXT
);

CREATE TABLE IF NOT EXISTS peers (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    name            TEXT NOT NULL,
    ip              TEXT UNIQUE NOT NULL,
    type            TEXT NOT NULL DEFAULT 'phone',
    mode            TEXT NOT NULL DEFAULT 'full',
    public_key      TEXT,
    private_key     TEXT,
    preshared_key   TEXT,
    created_at      TEXT NOT NULL DEFAULT (datetime('now')),
    updated_at      TEXT NOT NULL DEFAULT (datetime('now')),
    status          TEXT NOT NULL DEFAULT 'active',
    expiry_date     TEXT,
    group_name      TEXT,
    traffic_limit_mb INTEGER,
    config_file     TEXT
);

CREATE TABLE IF NOT EXISTS audit_log (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER,
    action      TEXT NOT NULL,
    target      TEXT,
    details     TEXT,
    created_at  TEXT NOT NULL DEFAULT (datetime('now')),
    ip_address  TEXT
);

CREATE TABLE IF NOT EXISTS settings (
    key   TEXT PRIMARY KEY,
    value TEXT
);
"""


def get_db() -> sqlite3.Connection:
    """Return a per-request SQLite connection (stored in flask.g)."""
    if "db" not in g:
        g.db = sqlite3.connect(str(DB_PATH), timeout=10)
        g.db.row_factory = sqlite3.Row
        g.db.execute("PRAGMA journal_mode=WAL")
        g.db.execute("PRAGMA foreign_keys=ON")
    return g.db


@app.teardown_appcontext
def _close_db(_exc: BaseException | None) -> None:
    db = g.pop("db", None)
    if db is not None:
        db.close()


def init_db() -> None:
    """Create tables if they don't exist."""
    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    conn.executescript(_DB_SCHEMA)
    conn.commit()
    conn.close()
    log.info("Database initialised: %s", DB_PATH)


# =============================================================================
# Startup helpers
# =============================================================================

DEFAULT_SETTINGS: dict[str, str] = {
    "DNS": "10.8.0.2",
    "MTU": "1360",
    "Jc": "2",
    "Jmin": "20",
    "Jmax": "200",
    "S1": "15",
    "S2": "20",
}


def _ensure_default_admin() -> None:
    """Create admin/admin user if no users exist."""
    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    count = conn.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    if count == 0:
        pw_hash = bcrypt.hashpw(b"admin", bcrypt.gensalt(rounds=12)).decode()
        conn.execute(
            "INSERT INTO users (username, password_hash) VALUES (?, ?)",
            ("admin", pw_hash),
        )
        conn.commit()
        log.warning(
            "╔═══════════════════════════════════════════════════════════╗"
        )
        log.warning(
            "║  Default admin created — username: admin, password: admin ║"
        )
        log.warning(
            "║  CHANGE THE PASSWORD IMMEDIATELY!                        ║"
        )
        log.warning(
            "╚═══════════════════════════════════════════════════════════╝"
        )
    conn.close()


def _load_default_settings() -> None:
    """Populate settings table with defaults (skip existing keys)."""
    conn = sqlite3.connect(str(DB_PATH), timeout=10)

    keys_env = _read_kv_file(KEYS_ENV_PATH)
    for h_key in ("H1", "H2", "H3", "H4"):
        if h_key in keys_env:
            DEFAULT_SETTINGS[h_key] = keys_env[h_key]

    for key, val in DEFAULT_SETTINGS.items():
        existing = conn.execute(
            "SELECT value FROM settings WHERE key = ?", (key,)
        ).fetchone()
        if existing is None:
            conn.execute("INSERT INTO settings (key, value) VALUES (?, ?)", (key, val))
    conn.commit()
    conn.close()
    log.info("Default settings loaded")


def _import_peers_from_json() -> None:
    """Import peers from vpn-output/peers.json into SQLite (if DB is empty)."""
    conn = sqlite3.connect(str(DB_PATH), timeout=10)
    count = conn.execute("SELECT COUNT(*) FROM peers").fetchone()[0]
    if count > 0:
        conn.close()
        return

    if not PEERS_JSON_PATH.is_file():
        conn.close()
        return

    try:
        peers = json.loads(PEERS_JSON_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        log.warning("Cannot read peers.json: %s", exc)
        conn.close()
        return

    imported = 0
    for p in peers:
        name = p.get("name", "unknown")
        ip = p.get("ip", "")
        if not ip:
            continue
        conn.execute(
            """INSERT OR IGNORE INTO peers
               (name, ip, type, public_key, private_key, created_at, config_file, status, mode)
               VALUES (?, ?, ?, ?, ?, ?, ?, 'active', 'full')""",
            (
                name,
                ip,
                p.get("type", "phone"),
                p.get("public_key", ""),
                p.get("private_key", ""),
                p.get("created", dt.datetime.now(dt.timezone.utc).isoformat()),
                p.get("config_file", ""),
            ),
        )
        imported += 1

    conn.commit()
    conn.close()
    if imported:
        log.info("Imported %d peers from peers.json", imported)


# =============================================================================
# Config folder: scan .conf files for peers
# =============================================================================


def _parse_peer_from_config_file(config_path: Path) -> dict | None:
    """Parse a WireGuard .conf file and return peer info (name, ip, config_file)."""
    if not config_path.is_file():
        return None
    try:
        text = config_path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None
    ip = ""
    for line in text.splitlines():
        line = line.strip()
        if line.startswith("Address") and "=" in line:
            _, _, val = line.partition("=")
            addr = val.strip()
            if "/" in addr:
                ip = addr.split("/")[0].strip()
            else:
                ip = addr
            break
    if not ip:
        return None
    stem = config_path.stem
    if stem.startswith("peer_"):
        m = re.match(r"^peer_(.+)_10_9_0_\d+$", stem)
        name = m.group(1).replace("_", "-") if m else stem[5:].replace("_", "-")
    elif stem in ("client", "phone", "tablet"):
        name = stem
    else:
        name = stem.replace("_", "-")
    return {
        "name": name,
        "ip": ip,
        "config_file": str(config_path),
        "source": "config_file",
    }


def _scan_peers_from_configs_dir() -> list[dict]:
    """Scan CONFIGS_DIR for all .conf files, return list of peer info (каждый файл = отдельный пир)."""
    result: list[dict] = []
    if not CONFIGS_DIR.is_dir():
        return result
    for path in sorted(CONFIGS_DIR.glob("*.conf")):
        peer = _parse_peer_from_config_file(path)
        if peer and peer["ip"]:
            result.append(peer)
    return result


# =============================================================================
# peers.json sync (write back)
# =============================================================================


def sync_peers_to_json() -> None:
    """Write current peers from SQLite back to vpn-output/peers.json."""
    try:
        conn = sqlite3.connect(str(DB_PATH), timeout=10)
        conn.row_factory = sqlite3.Row
        rows = conn.execute(
            "SELECT name, ip, type, public_key, private_key, created_at, config_file FROM peers"
        ).fetchall()
        conn.close()

        data = [
            {
                "name": r["name"],
                "ip": r["ip"],
                "type": r["type"],
                "public_key": r["public_key"] or "",
                "private_key": r["private_key"] or "",
                "created": r["created_at"],
                "config_file": r["config_file"] or "",
            }
            for r in rows
        ]

        PEERS_JSON_PATH.parent.mkdir(parents=True, exist_ok=True)
        tmp = PEERS_JSON_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2, ensure_ascii=False), encoding="utf-8")
        tmp.replace(PEERS_JSON_PATH)
        log.info("Synced %d peers to peers.json", len(data))
    except Exception as exc:
        log.error("Failed to sync peers.json: %s", exc)


# =============================================================================
# SSH helpers
# =============================================================================


def _ssh_connect(host: str, user: str, key_path: str, password: str) -> paramiko.SSHClient:
    """Open an SSH connection using key or password."""
    client = paramiko.SSHClient()
    client.load_system_host_keys()
    client.set_missing_host_key_policy(paramiko.RejectPolicy())

    connect_kwargs: dict[str, Any] = {
        "hostname": host,
        "username": user,
        "timeout": 30,
        "banner_timeout": 30,
    }

    resolved_key = _resolve_key_path(key_path)
    if resolved_key and Path(resolved_key).is_file():
        connect_kwargs["key_filename"] = resolved_key
    elif password:
        connect_kwargs["password"] = password
    else:
        connect_kwargs["key_filename"] = resolved_key or key_path

    client.connect(**connect_kwargs)
    return client


def _resolve_key_path(key_path: str) -> str | None:
    """Try to resolve SSH key path: absolute, PROJECT_ROOT, or ~/.ssh/."""
    if not key_path or not key_path.strip():
        return None
    key_path = key_path.strip()
    # 1) Absolute path or path with ~
    expanded = os.path.expanduser(key_path)
    p = Path(expanded)
    if p.is_file():
        return str(p)
    # 2) PROJECT_ROOT / key_path (e.g. .ssh/key)
    candidate = PROJECT_ROOT / key_path
    if candidate.is_file():
        return str(candidate)
    # 3) ~/.ssh/ for paths like .ssh/key (without ~)
    normalized = key_path.replace("\\", "/").strip()
    if normalized.startswith(".ssh/"):
        name = Path(normalized).name
    else:
        name = Path(key_path).name
    if name:
        home_key = Path.home() / ".ssh" / name
        if home_key.is_file():
            return str(home_key)
    return key_path


def ssh_exec(host: str, user: str, key_path: str, password: str, command: str) -> str:
    """Execute a command on a remote server via SSH and return stdout."""
    client = _ssh_connect(host, user, key_path, password)
    try:
        _stdin, stdout, stderr = client.exec_command(command, timeout=30)
        out = stdout.read().decode(errors="replace")
        err_out = stderr.read().decode(errors="replace")
        if err_out:
            log.debug("SSH stderr from %s: %s", host, err_out.strip())
        return out
    finally:
        client.close()


def ssh_upload(host: str, user: str, key_path: str, password: str,
               local_path: str, remote_path: str) -> None:
    """Upload a file to a remote server via SFTP."""
    client = _ssh_connect(host, user, key_path, password)
    try:
        sftp = client.open_sftp()
        sftp.put(local_path, remote_path)
        sftp.close()
    finally:
        client.close()


def _vps1_ssh(command: str) -> str:
    """Shortcut: run command on VPS1."""
    return ssh_exec(
        get_env("VPS1_IP"),
        get_env("VPS1_USER", "root"),
        get_env("VPS1_KEY"),
        get_env("VPS1_PASS"),
        command,
    )


# =============================================================================
# JWT helpers
# =============================================================================


def _create_token(user_id: int, username: str) -> tuple[str, str]:
    """Return (token, expires_at_iso). Token as str for JSON."""
    ttl = app.config["JWT_TTL_HOURS"]
    exp = dt.datetime.now(dt.timezone.utc) + dt.timedelta(hours=ttl)
    payload = {"sub": user_id, "usr": username, "exp": exp}
    raw = jwt.encode(payload, app.config["SECRET_KEY"], algorithm="HS256")
    token = raw if isinstance(raw, str) else raw.decode("utf-8")
    return token, exp.isoformat()


def _decode_token(token: str) -> dict | None:
    try:
        return jwt.decode(token, app.config["SECRET_KEY"], algorithms=["HS256"])
    except jwt.ExpiredSignatureError:
        log.debug("JWT expired")
        return None
    except jwt.InvalidTokenError as e:
        log.warning("JWT invalid: %s", e)
        return None


def _store_session(token: str) -> str:
    """Store server-side session and return a new session ID."""
    sid = secrets.token_hex(24)
    with _sessions_lock:
        _sessions[sid] = {"token": token, "created_at": time.time()}
    return sid


def _get_session_token(sid: str) -> str | None:
    """Resolve session ID to token with TTL check."""
    now = time.time()
    with _sessions_lock:
        item = _sessions.get(sid)
        if not item:
            return None
        created_at = float(item.get("created_at", 0))
        if now - created_at > SESSION_TTL_SEC:
            _sessions.pop(sid, None)
            return None
        return item.get("token")


def _get_token_from_request() -> str | None:
    """Get JWT from Authorization header, or from session cookie (session_id -> token on server)."""
    auth_header = request.headers.get("Authorization", "")
    if auth_header.startswith("Bearer "):
        t = auth_header[7:].strip()
        if t:
            return t
    sid = request.cookies.get(SESSION_COOKIE_NAME)
    if sid:
        token = _get_session_token(sid)
        if token:
            return token
    return None


def _is_local_request() -> bool:
    """True if request is from localhost (dev convenience)."""
    addr = (request.remote_addr or "").strip()
    return addr in ("127.0.0.1", "::1", "localhost", "")


def auth_required(fn):
    """Decorator: require valid JWT (header or cookie)."""
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        token = _get_token_from_request()
        if not token:
            return jsonify({"error": "Missing or invalid Authorization header"}), 401
        if token in _blacklisted_tokens:
            return jsonify({"error": "Token has been invalidated"}), 401
        payload = _decode_token(token)
        if payload is None:
            return jsonify({"error": "Invalid or expired token"}), 401
        g.user_id = payload["sub"]
        g.username = payload["usr"]
        g.token = token
        return fn(*args, **kwargs)
    return wrapper


def auth_required_or_local(fn):
    """Require auth, but allow localhost bypass only for read-only monitoring."""
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        is_monitoring_readonly = (
            request.method in {"GET", "HEAD", "OPTIONS"}
            and request.path in {"/api/monitoring/data", "/api/monitoring/peers"}
        )
        if _is_local_request() and is_monitoring_readonly:
            g.user_id = 1
            g.username = "local"
            g.token = None
            return fn(*args, **kwargs)
        return auth_required(fn)(*args, **kwargs)
    return wrapper


# =============================================================================
# Audit logging
# =============================================================================


def audit(action: str, target: str = "", details: Any = None) -> None:
    """Write an entry to the audit_log table."""
    try:
        db = get_db()
        db.execute(
            "INSERT INTO audit_log (user_id, action, target, details, ip_address) VALUES (?, ?, ?, ?, ?)",
            (
                getattr(g, "user_id", None),
                action,
                target,
                json.dumps(details) if details else None,
                request.remote_addr,
            ),
        )
        db.commit()
    except Exception as exc:
        log.error("Audit log write failed: %s", exc)


# =============================================================================
# Key generation
# =============================================================================

MTU_BY_TYPE: dict[str, int] = {
    "phone": 1280,
    "mobile": 1280,
    "tablet": 1360,
    "ios": 1280,
    "android": 1280,
    "pc": 1360,
    "desktop": 1360,
    "laptop": 1360,
    "computer": 1360,
    "router": 1400,
    "mikrotik": 1400,
    "openwrt": 1400,
}


def _generate_keypair_ssh() -> tuple[str, str]:
    """Generate WireGuard keypair via SSH on VPS1. Returns (private, public)."""
    out = _vps1_ssh(
        "PRIV=$(awg genkey); PUB=$(printf '%s' \"$PRIV\" | awg pubkey); "
        "printf 'PRIV=%s\\nPUB=%s\\n' \"$PRIV\" \"$PUB\""
    )
    priv = pub = ""
    for line in out.strip().splitlines():
        if line.startswith("PRIV="):
            priv = line[5:]
        elif line.startswith("PUB="):
            pub = line[4:]
    return priv, pub


def _generate_psk_ssh() -> str:
    """Generate a preshared key via SSH on VPS1."""
    return _vps1_ssh("awg genpsk").strip()


def _get_server_info() -> dict[str, str]:
    """Fetch server public key, port, and junk parameters from VPS1."""
    out = _vps1_ssh(
        'echo "=PUB="; awg show awg1 public-key; '
        'echo "=PORT="; awg show awg1 listen-port; '
        'echo "=JUNK="; '
        'awk "/^\\[Interface\\]/{f=1;next} f && /^\\[/{exit} '
        'f && /^(Jc|Jmin|Jmax|S1|S2|H1|H2|H3|H4)[[:space:]]*=/{print}" '
        "/etc/amnezia/amneziawg/awg1.conf"
    )
    info: dict[str, str] = {}
    current_tag = ""
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("=") and line.endswith("="):
            current_tag = line.strip("=")
            continue
        if current_tag == "PUB" and line:
            info["server_public_key"] = line
        elif current_tag == "PORT" and line:
            info["server_port"] = line
        elif current_tag == "JUNK" and "=" in line:
            k, _, v = line.partition("=")
            info[k.strip()] = v.strip()
    return info


def _allocate_ip(db: sqlite3.Connection) -> str | None:
    """Find the next available IP in 10.9.0.3-254."""
    used = {row[0] for row in db.execute("SELECT ip FROM peers").fetchall()}
    for i in range(3, 255):
        candidate = f"10.9.0.{i}"
        if candidate not in used:
            return candidate
    return None


def _build_config(
    private_key: str,
    peer_ip: str,
    preshared_key: str,
    device_type: str,
    settings: dict[str, str],
    server_info: dict[str, str],
) -> str:
    """Build a .conf file content for a peer."""
    mtu = MTU_BY_TYPE.get(device_type, 1360)
    dns = settings.get("DNS", "10.8.0.2")
    endpoint_ip = get_env("VPS1_IP")
    endpoint_port = server_info.get("server_port", "51820")

    lines = [
        "[Interface]",
        f"PrivateKey = {private_key}",
        f"Address = {peer_ip}/32",
        f"DNS = {dns}",
        f"MTU = {mtu}",
    ]

    for param in ("Jc", "Jmin", "Jmax", "S1", "S2", "H1", "H2", "H3", "H4"):
        val = server_info.get(param) or settings.get(param)
        if val:
            lines.append(f"{param} = {val}")

    lines += [
        "",
        "[Peer]",
        f"PublicKey = {server_info.get('server_public_key', '')}",
        f"PresharedKey = {preshared_key}",
        f"Endpoint = {endpoint_ip}:{endpoint_port}",
        "AllowedIPs = 0.0.0.0/0",
        "PersistentKeepalive = 25",
    ]
    return "\n".join(lines) + "\n"


def _add_peer_to_server(public_key: str, preshared_key: str, peer_ip: str) -> None:
    """Register a peer on VPS1 via SSH (awg set + config append)."""
    _vps1_ssh(
        f"printf '%s' '{preshared_key}' > /tmp/psk && "
        f"awg set awg1 peer '{public_key}' preshared-key /tmp/psk allowed-ips '{peer_ip}/32' && "
        f"rm -f /tmp/psk"
    )


def _remove_peer_from_server(public_key: str) -> None:
    """Remove a peer from VPS1 via SSH."""
    if public_key:
        _vps1_ssh(f"awg set awg1 peer '{public_key}' remove")


def _get_all_settings(db: sqlite3.Connection) -> dict[str, str]:
    """Return all settings as a dict."""
    rows = db.execute("SELECT key, value FROM settings").fetchall()
    return {r["key"]: r["value"] for r in rows}


# =============================================================================
# QR code generation
# =============================================================================


def _generate_qr_base64(text: str) -> str:
    """Generate a QR code PNG and return it as a base64 string."""
    qr = qrcode.QRCode(
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=6,
        border=2,
    )
    qr.add_data(text)
    qr.make(fit=True)
    img = qr.make_image(fill_color="black", back_color="white")
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode()


# =============================================================================
# API: Auth
# =============================================================================


@app.route("/api/auth/login", methods=["POST"])
def auth_login():
    """Authenticate user and return JWT token."""
    ip = request.remote_addr
    if not _check_rate_limit(ip):
        return jsonify({"error": "Too many login attempts. Try again later."}), 429

    data = request.get_json(silent=True) or {}
    username = data.get("username", "").strip()
    password = data.get("password", "")

    if not username or not password:
        return jsonify({"error": "Username and password required"}), 400

    db = get_db()
    user = db.execute(
        "SELECT id, username, password_hash, created_at, last_login FROM users WHERE username = ?",
        (username,),
    ).fetchone()

    stored_hash = (user["password_hash"] or "").strip() if user else ""
    if user is None or not stored_hash or not bcrypt.checkpw(
        password.encode("utf-8"), stored_hash.encode("utf-8")
    ):
        return jsonify({"error": "Invalid credentials"}), 401

    token, expires_at = _create_token(user["id"], user["username"])
    db.execute(
        "UPDATE users SET last_login = datetime('now') WHERE id = ?", (user["id"],)
    )
    db.commit()

    g.user_id = user["id"]
    g.username = user["username"]
    _clear_rate_limit(request.remote_addr or "")
    audit("login", user["username"])

    user_info = {
        "id": user["id"],
        "username": user["username"],
        "created_at": user["created_at"],
        "last_login": user["last_login"],
    }
    token_str = (token if isinstance(token, str) else str(token)).strip()
    sid = _store_session(token_str)
    resp = jsonify({"token": token_str, "expires_at": expires_at, "user": user_info})
    resp.set_cookie(
        SESSION_COOKIE_NAME,
        sid,
        httponly=True,
        samesite="Lax",
        secure=bool(app.config.get("SESSION_COOKIE_SECURE", False)),
        path="/",
        max_age=SESSION_TTL_SEC,
    )
    return resp


@app.route("/api/auth/logout", methods=["POST"])
@auth_required
def auth_logout():
    """Invalidate the current JWT token and clear session cookie."""
    _blacklisted_tokens.add(g.token)
    sid = request.cookies.get(SESSION_COOKIE_NAME)
    if sid:
        with _sessions_lock:
            _sessions.pop(sid, None)
    audit("logout")
    resp = jsonify({"ok": True})
    resp.delete_cookie(SESSION_COOKIE_NAME, path="/")
    resp.delete_cookie("admin_token", path="/")
    return resp


@app.route("/api/auth/change-password", methods=["POST"])
@auth_required
def auth_change_password():
    """Change password for the current user."""
    data = request.get_json(silent=True) or {}
    old_pw = data.get("old_password", "")
    new_pw = data.get("new_password", "")

    if not old_pw or not new_pw:
        return jsonify({"error": "old_password and new_password required"}), 400
    if len(new_pw) < 6:
        return jsonify({"error": "Password must be at least 6 characters"}), 400

    db = get_db()
    user = db.execute(
        "SELECT password_hash FROM users WHERE id = ?", (g.user_id,)
    ).fetchone()

    if not bcrypt.checkpw(old_pw.encode(), user["password_hash"].encode()):
        return jsonify({"error": "Current password is incorrect"}), 401

    new_hash = bcrypt.hashpw(new_pw.encode(), bcrypt.gensalt(rounds=12)).decode()
    db.execute(
        "UPDATE users SET password_hash = ? WHERE id = ?", (new_hash, g.user_id)
    )
    db.commit()
    audit("change_password")
    return jsonify({"ok": True})


@app.route("/api/auth/me", methods=["GET"])
@auth_required
def auth_me():
    """Return current user info."""
    db = get_db()
    user = db.execute(
        "SELECT id, username, created_at, last_login FROM users WHERE id = ?",
        (g.user_id,),
    ).fetchone()
    return jsonify(dict(user))


# =============================================================================
# API: Peers
# =============================================================================


def _peer_to_dict(row: sqlite3.Row) -> dict:
    return dict(row)


def _split_wg_dump_line(line: str) -> list[str]:
    """Split `wg/awg show ... dump` line (tab or space separated)."""
    return [p for p in re.split(r"\s+", line.strip()) if p]


def _extract_peer_ip(allowed_ips: str) -> str | None:
    """Extract first IPv4 from AllowedIPs string."""
    if not allowed_ips:
        return None
    m = re.search(r"(\d{1,3}(?:\.\d{1,3}){3})(?:/\d{1,2})?", allowed_ips)
    return m.group(1) if m else None


def _get_monitoring_by_ip() -> dict[str, dict]:
    """Fetch monitoring peers from VPS1, return dict ip -> {handshake_age_sec, rx_bytes, tx_bytes}."""
    result: dict[str, dict] = {}
    dump_cmd = (
        "sudo -n awg show awg1 dump 2>/dev/null || "
        "sudo -n wg show awg1 dump 2>/dev/null || "
        "awg show awg1 dump 2>/dev/null || "
        "wg show awg1 dump 2>/dev/null"
    )
    try:
        dump = _vps1_ssh(dump_cmd)
    except Exception as exc:
        log.debug("Monitoring by IP (SSH): %s", exc)
        return result
    now = int(time.time())
    for line in dump.strip().splitlines():
        parts = _split_wg_dump_line(line)
        if len(parts) < 7:
            continue
        allowed_ips = parts[3] if len(parts) > 3 else ""
        peer_ip = _extract_peer_ip(allowed_ips)
        if not peer_ip:
            continue
        try:
            latest_handshake = int(parts[4]) if len(parts) > 4 and parts[4] and parts[4] != "0" else 0
        except (ValueError, TypeError):
            latest_handshake = 0
        try:
            rx_bytes = int(parts[5]) if len(parts) > 5 and parts[5] else 0
        except (ValueError, TypeError):
            rx_bytes = 0
        try:
            tx_bytes = int(parts[6]) if len(parts) > 6 and parts[6] else 0
        except (ValueError, TypeError):
            tx_bytes = 0
        handshake_age = now - latest_handshake if latest_handshake > 0 else None
        result[peer_ip] = {
            "handshake_age_sec": handshake_age,
            "rx_bytes": rx_bytes,
            "tx_bytes": tx_bytes,
            "latest_handshake": latest_handshake,
        }
    return result


@app.route("/api/peers", methods=["GET"])
@auth_required
def peers_list():
    """List all issued peers: from DB + config folder. Includes connection status."""
    db = get_db()
    conditions: list[str] = []
    params: list[str] = []

    status = request.args.get("status")
    if status:
        conditions.append("status = ?")
        params.append(status)

    ptype = request.args.get("type")
    if ptype:
        conditions.append("type = ?")
        params.append(ptype)

    group = request.args.get("group")
    if group:
        conditions.append("group_name = ?")
        params.append(group)

    search = request.args.get("search")
    if search:
        conditions.append("(name LIKE ? OR ip LIKE ?)")
        params.extend([f"%{search}%", f"%{search}%"])

    where = " WHERE " + " AND ".join(conditions) if conditions else ""
    rows = db.execute(f"SELECT * FROM peers{where} ORDER BY id", params).fetchall()
    db_peers = [_peer_to_dict(r) for r in rows]
    db_config_files = set()
    for p in db_peers:
        cf = p.get("config_file")
        if cf:
            try:
                db_config_files.add(str(Path(cf).resolve()))
            except (OSError, RuntimeError):
                db_config_files.add(str(Path(cf)))

    config_peers = _scan_peers_from_configs_dir()
    for cp in config_peers:
        if cp["config_file"] and str(Path(cp["config_file"]).resolve()) in db_config_files:
            continue
        if status and status != "from_config":
            continue
        if search and search.lower() not in (cp.get("name") or "").lower() and search not in (cp.get("ip") or ""):
            continue
        db_peers.append({
                "id": None,
                "name": cp["name"],
                "ip": cp["ip"],
                "type": "phone",
                "mode": "full",
                "public_key": None,
                "private_key": None,
                "preshared_key": None,
                "created_at": None,
                "updated_at": None,
                "status": "from_config",
                "expiry_date": None,
                "group_name": None,
                "traffic_limit_mb": None,
                "config_file": cp["config_file"],
                "source": "config_file",
            })

    try:
        mon_by_ip = _get_monitoring_by_ip()
    except Exception as exc:
        log.debug("peers_list: monitoring fetch failed: %s", exc)
        mon_by_ip = {}
    CONNECTED_HS_SEC = max(15, PEER_ONLINE_HANDSHAKE_SEC)
    for p in db_peers:
        ip = p.get("ip")
        mon = mon_by_ip.get(ip) if ip else None
        p["connection_status"] = "online" if mon and mon.get("handshake_age_sec") is not None and mon["handshake_age_sec"] < CONNECTED_HS_SEC else "offline"
        p["handshake_age_sec"] = mon.get("handshake_age_sec") if mon else None
        p["rx_bytes"] = mon.get("rx_bytes") if mon else None
        p["tx_bytes"] = mon.get("tx_bytes") if mon else None
        p["connection_threshold_sec"] = CONNECTED_HS_SEC

    return jsonify(db_peers)


@app.route("/api/peers", methods=["POST"])
@auth_required
def peers_create():
    """Create a new peer: generate keys, allocate IP, register on server."""
    data = request.get_json(silent=True) or {}
    name = data.get("name", "").strip()
    device_type = data.get("type", "phone").strip().lower()
    mode = data.get("mode", "full").strip().lower()
    group_name = data.get("group_name")
    expiry_date = data.get("expiry_date")
    traffic_limit_mb = data.get("traffic_limit_mb")

    if not name:
        return jsonify({"error": "name is required"}), 400
    if mode not in {"full", "split"}:
        return jsonify({"error": "mode must be one of: full, split"}), 400

    group_name = str(group_name).strip() if group_name is not None else None
    if group_name == "":
        group_name = None

    if expiry_date in (None, ""):
        expiry_date = None
    else:
        expiry_date = str(expiry_date).strip()
        if not re.match(r"^\d{4}-\d{2}-\d{2}$", expiry_date):
            return jsonify({"error": "expiry_date must be YYYY-MM-DD"}), 400

    if traffic_limit_mb in (None, ""):
        traffic_limit_mb = None
    else:
        try:
            traffic_limit_mb = int(traffic_limit_mb)
        except (TypeError, ValueError):
            return jsonify({"error": "traffic_limit_mb must be an integer"}), 400
        if traffic_limit_mb < 0:
            return jsonify({"error": "traffic_limit_mb must be >= 0"}), 400

    db = get_db()

    existing = db.execute("SELECT id FROM peers WHERE name = ?", (name,)).fetchone()
    if existing:
        return jsonify({"error": f"Peer with name '{name}' already exists"}), 409

    ip = _allocate_ip(db)
    if not ip:
        return jsonify({"error": "No available IPs in 10.9.0.3-254 range"}), 507

    try:
        priv, pub = _generate_keypair_ssh()
        psk = _generate_psk_ssh()
    except Exception as exc:
        log.error("Key generation failed: %s", exc)
        return jsonify({"error": f"Key generation failed: {exc}"}), 500

    if not priv or not pub:
        return jsonify({"error": "Failed to generate keypair on VPS1"}), 500

    settings = _get_all_settings(db)
    try:
        server_info = _get_server_info()
    except Exception as exc:
        log.error("Failed to get server info: %s", exc)
        return jsonify({"error": f"Cannot reach VPS1: {exc}"}), 502

    config_content = _build_config(priv, ip, psk, device_type, settings, server_info)

    safe_name = re.sub(r"[^a-zA-Z0-9_-]", "_", name)
    safe_ip = ip.replace(".", "_")
    config_filename = f"peer_{safe_name}_{safe_ip}.conf"
    config_path = CONFIGS_DIR / config_filename
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(config_content, encoding="utf-8")

    try:
        _add_peer_to_server(pub, psk, ip)
    except Exception as exc:
        log.error("Failed to add peer to VPS1: %s", exc)
        config_path.unlink(missing_ok=True)
        return jsonify({"error": f"Failed to register peer on server: {exc}"}), 502

    now = dt.datetime.now(dt.timezone.utc).isoformat()
    db.execute(
        """INSERT INTO peers
           (name, ip, type, mode, public_key, private_key, preshared_key,
            created_at, updated_at, status, config_file, group_name, expiry_date, traffic_limit_mb)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 'active', ?, ?, ?, ?)""",
        (
            name,
            ip,
            device_type,
            mode,
            pub,
            priv,
            psk,
            now,
            now,
            str(config_path),
            group_name,
            expiry_date,
            traffic_limit_mb,
        ),
    )
    db.commit()

    sync_peers_to_json()
    audit("peer_created", name, {"ip": ip, "type": device_type, "mode": mode})

    peer = db.execute("SELECT * FROM peers WHERE ip = ?", (ip,)).fetchone()
    return jsonify(_peer_to_dict(peer)), 201


@app.route("/api/peers/batch", methods=["POST"])
@auth_required
def peers_batch_create():
    """Batch-create peers from prefix+count or CSV data."""
    data = request.get_json(silent=True) or {}
    results: list[dict] = []
    errors: list[dict] = []

    csv_data = data.get("csv")
    if csv_data:
        lines = csv_data.strip().splitlines()
        for line in lines:
            parts = [p.strip() for p in line.split(",")]
            if not parts or parts[0].lower() == "name":
                continue
            name = parts[0] if len(parts) > 0 else ""
            ptype = parts[1] if len(parts) > 1 else "phone"
            pmode = parts[2] if len(parts) > 2 else "full"
            if not name:
                continue
            with app.test_request_context(
                "/api/peers",
                method="POST",
                json={"name": name, "type": ptype, "mode": pmode},
                headers={"Authorization": request.headers.get("Authorization", "")},
            ):
                g.user_id = getattr(g, "user_id", None)
                g.username = getattr(g, "username", None)
                g.token = getattr(g, "token", None)
                resp = peers_create()
                resp_data = resp[0].get_json() if isinstance(resp, tuple) else resp.get_json()
                status_code = resp[1] if isinstance(resp, tuple) else 200
                if status_code < 300:
                    results.append(resp_data)
                else:
                    errors.append({"name": name, "error": resp_data.get("error", "unknown")})
    else:
        prefix = data.get("prefix", "peer")
        count = int(data.get("count", 0))
        ptype = data.get("type", "phone")
        pmode = data.get("mode", "full")

        if count <= 0:
            return jsonify({"error": "count must be > 0"}), 400
        if count > 252:
            return jsonify({"error": "count exceeds max available IPs (252)"}), 400

        for i in range(1, count + 1):
            name = f"{prefix}-{i:03d}"
            with app.test_request_context(
                "/api/peers",
                method="POST",
                json={"name": name, "type": ptype, "mode": pmode},
                headers={"Authorization": request.headers.get("Authorization", "")},
            ):
                g.user_id = getattr(g, "user_id", None)
                g.username = getattr(g, "username", None)
                g.token = getattr(g, "token", None)
                resp = peers_create()
                resp_data = resp[0].get_json() if isinstance(resp, tuple) else resp.get_json()
                status_code = resp[1] if isinstance(resp, tuple) else 200
                if status_code < 300:
                    results.append(resp_data)
                else:
                    errors.append({"name": name, "error": resp_data.get("error", "unknown")})

    audit("peers_batch_created", "", {"created": len(results), "failed": len(errors)})
    return jsonify({"created": results, "errors": errors, "total": len(results), "failed": len(errors)})


@app.route("/api/peers/<int:peer_id>", methods=["GET"])
@auth_required
def peers_get(peer_id: int):
    """Get a single peer by ID."""
    db = get_db()
    peer = db.execute("SELECT * FROM peers WHERE id = ?", (peer_id,)).fetchone()
    if peer is None:
        return jsonify({"error": "Peer not found"}), 404
    return jsonify(_peer_to_dict(peer))


@app.route("/api/peers/<int:peer_id>", methods=["PUT"])
@auth_required
def peers_update(peer_id: int):
    """Update peer metadata (name, type, mode, group, status, expiry, traffic limit)."""
    db = get_db()
    peer = db.execute("SELECT * FROM peers WHERE id = ?", (peer_id,)).fetchone()
    if peer is None:
        return jsonify({"error": "Peer not found"}), 404

    data = request.get_json(silent=True) or {}
    allowed_fields = {
        "name",
        "type",
        "mode",
        "group_name",
        "status",
        "expiry_date",
        "traffic_limit_mb",
        "public_key",
        "private_key",
        "preshared_key",
        "config_file",
    }
    allowed_statuses = {"active", "disabled", "revoked"}
    allowed_modes = {"full", "split"}
    updates: list[str] = []
    params: list[Any] = []
    changes: dict[str, Any] = {}

    for field in allowed_fields:
        if field in data:
            value = data[field]

            if field == "name":
                value = str(value or "").strip()
                if not value:
                    return jsonify({"error": "name cannot be empty"}), 400
                existing = db.execute(
                    "SELECT id FROM peers WHERE name = ? AND id != ?",
                    (value, peer_id),
                ).fetchone()
                if existing:
                    return jsonify({"error": f"Peer with name '{value}' already exists"}), 409
            elif field == "type":
                value = str(value or "").strip().lower()
                if not value:
                    return jsonify({"error": "type cannot be empty"}), 400
            elif field == "mode":
                value = str(value or "").strip().lower()
                if value not in allowed_modes:
                    return jsonify({"error": f"mode must be one of: {', '.join(sorted(allowed_modes))}"}), 400
            elif field == "status":
                value = str(value or "").strip().lower()
                if value not in allowed_statuses:
                    return jsonify({"error": f"status must be one of: {', '.join(sorted(allowed_statuses))}"}), 400
            elif field == "group_name":
                value = str(value).strip() if value is not None else None
                if value == "":
                    value = None
            elif field == "expiry_date":
                if value in (None, ""):
                    value = None
                else:
                    value = str(value).strip()
                    if not re.match(r"^\d{4}-\d{2}-\d{2}$", value):
                        return jsonify({"error": "expiry_date must be YYYY-MM-DD"}), 400
            elif field == "traffic_limit_mb":
                if value in (None, ""):
                    value = None
                else:
                    try:
                        value = int(value)
                    except (ValueError, TypeError):
                        return jsonify({"error": "traffic_limit_mb must be an integer"}), 400
                    if value < 0:
                        return jsonify({"error": "traffic_limit_mb must be >= 0"}), 400
            elif field in {"public_key", "private_key", "preshared_key", "config_file"}:
                value = str(value).strip() if value is not None else None
                if value == "":
                    value = None

            updates.append(f"{field} = ?")
            params.append(value)
            changes[field] = value

    if not updates:
        return jsonify({"error": "No valid fields to update"}), 400

    updates.append("updated_at = datetime('now')")
    params.append(peer_id)

    try:
        db.execute(
            f"UPDATE peers SET {', '.join(updates)} WHERE id = ?", params
        )
    except sqlite3.IntegrityError as exc:
        msg = str(exc).lower()
        if "name" in msg:
            return jsonify({"error": "Peer name must be unique"}), 409
        return jsonify({"error": f"Constraint error: {exc}"}), 409
    db.commit()

    sync_peers_to_json()
    audit("peer_updated", peer["name"], changes)

    updated = db.execute("SELECT * FROM peers WHERE id = ?", (peer_id,)).fetchone()
    return jsonify(_peer_to_dict(updated))


@app.route("/api/peers/<int:peer_id>", methods=["DELETE"])
@auth_required
def peers_delete(peer_id: int):
    """Delete a peer from DB and remove from VPN server."""
    db = get_db()
    peer = db.execute("SELECT * FROM peers WHERE id = ?", (peer_id,)).fetchone()
    if peer is None:
        return jsonify({"error": "Peer not found"}), 404

    try:
        _remove_peer_from_server(peer["public_key"])
    except Exception as exc:
        log.warning("Failed to remove peer from server (continuing): %s", exc)

    config_path = _resolve_config_path(peer["config_file"])
    if config_path:
        config_path.unlink(missing_ok=True)

    db.execute("DELETE FROM peers WHERE id = ?", (peer_id,))
    db.commit()

    sync_peers_to_json()
    audit("peer_deleted", peer["name"], {"ip": peer["ip"]})
    return jsonify({"ok": True, "deleted": peer["name"]})


@app.route("/api/peers/<int:peer_id>/disable", methods=["POST"])
@auth_required
def peers_disable(peer_id: int):
    """Disable a peer on the VPN server without deleting it."""
    db = get_db()
    peer = db.execute("SELECT * FROM peers WHERE id = ?", (peer_id,)).fetchone()
    if peer is None:
        return jsonify({"error": "Peer not found"}), 404

    try:
        _remove_peer_from_server(peer["public_key"])
    except Exception as exc:
        log.warning("Failed to disable peer on server: %s", exc)

    db.execute(
        "UPDATE peers SET status = 'disabled', updated_at = datetime('now') WHERE id = ?",
        (peer_id,),
    )
    db.commit()
    audit("peer_disabled", peer["name"])
    return jsonify({"ok": True, "status": "disabled"})


@app.route("/api/peers/<int:peer_id>/enable", methods=["POST"])
@auth_required
def peers_enable(peer_id: int):
    """Re-enable a disabled peer on the VPN server."""
    db = get_db()
    peer = db.execute("SELECT * FROM peers WHERE id = ?", (peer_id,)).fetchone()
    if peer is None:
        return jsonify({"error": "Peer not found"}), 404

    if peer["public_key"] and peer["preshared_key"]:
        try:
            _add_peer_to_server(peer["public_key"], peer["preshared_key"], peer["ip"])
        except Exception as exc:
            log.warning("Failed to re-enable peer on server: %s", exc)
            return jsonify({"error": f"Failed to re-enable on server: {exc}"}), 502

    db.execute(
        "UPDATE peers SET status = 'active', updated_at = datetime('now') WHERE id = ?",
        (peer_id,),
    )
    db.commit()
    audit("peer_enabled", peer["name"])
    return jsonify({"ok": True, "status": "active"})


def _resolve_config_path(config_file: str | None) -> Path | None:
    """Resolve config file path (absolute or relative to PROJECT_ROOT)."""
    if not config_file:
        return None
    p = Path(config_file)
    if p.is_file():
        return p
    candidate = PROJECT_ROOT / config_file
    if candidate.is_file():
        return candidate
    candidate = CONFIGS_DIR / Path(config_file).name
    return candidate if candidate.is_file() else None


@app.route("/api/peers/<int:peer_id>/config", methods=["GET"])
@auth_required
def peers_config(peer_id: int):
    """Download the .conf file for a peer."""
    db = get_db()
    peer = db.execute("SELECT * FROM peers WHERE id = ?", (peer_id,)).fetchone()
    if peer is None:
        return jsonify({"error": "Peer not found"}), 404

    config_path = _resolve_config_path(peer["config_file"])
    if config_path:
        content = config_path.read_text(encoding="utf-8")
    elif peer["private_key"]:
        settings = _get_all_settings(db)
        try:
            server_info = _get_server_info()
        except Exception:
            server_info = {}
        content = _build_config(
            peer["private_key"],
            peer["ip"],
            peer["preshared_key"] or "",
            peer["type"],
            settings,
            server_info,
        )
    else:
        return jsonify({"error": "Config not available"}), 404

    safe_name = re.sub(r"[^a-zA-Z0-9_-]", "_", peer["name"])
    return Response(
        content,
        mimetype="text/plain",
        headers={"Content-Disposition": f'attachment; filename="{safe_name}.conf"'},
    )


@app.route("/api/peers/by-ip/<path:peer_ip>/config", methods=["GET"])
@auth_required
def peers_config_by_ip(peer_ip: str):
    """Download .conf file for a peer by IP (для пиров из папки config)."""
    peer_ip = peer_ip.replace("_", ".")
    for cp in _scan_peers_from_configs_dir():
        if cp["ip"] == peer_ip:
            config_path = Path(cp["config_file"])
            if not config_path.is_file():
                config_path = CONFIGS_DIR / Path(cp["config_file"]).name
            if config_path.is_file():
                content = config_path.read_text(encoding="utf-8")
                safe_name = re.sub(r"[^a-zA-Z0-9_-]", "_", cp["name"])
                return Response(
                    content,
                    mimetype="text/plain",
                    headers={"Content-Disposition": f'attachment; filename="{safe_name}.conf"'},
                )
    return jsonify({"error": "Config not found"}), 404


@app.route("/api/peers/<int:peer_id>/qr", methods=["GET"])
@auth_required
def peers_qr(peer_id: int):
    """Get QR code as base64 PNG for a peer's config."""
    db = get_db()
    peer = db.execute("SELECT * FROM peers WHERE id = ?", (peer_id,)).fetchone()
    if peer is None:
        return jsonify({"error": "Peer not found"}), 404

    config_path = _resolve_config_path(peer["config_file"])
    if config_path:
        content = config_path.read_text(encoding="utf-8")
    elif peer["private_key"]:
        settings = _get_all_settings(db)
        try:
            server_info = _get_server_info()
        except Exception:
            server_info = {}
        content = _build_config(
            peer["private_key"],
            peer["ip"],
            peer["preshared_key"] or "",
            peer["type"],
            settings,
            server_info,
        )
    else:
        return jsonify({"error": "Config not available for QR"}), 404

    qr_b64 = _generate_qr_base64(content)
    return jsonify({"qr_png_base64": qr_b64})


@app.route("/api/peers/stats", methods=["GET"])
@auth_required
def peers_stats():
    """Return subnet statistics: total, used, available IPs."""
    db = get_db()
    total_range = 252  # 10.9.0.3 — 10.9.0.254
    used = db.execute("SELECT COUNT(*) FROM peers").fetchone()[0]
    by_status = db.execute(
        "SELECT status, COUNT(*) as cnt FROM peers GROUP BY status"
    ).fetchall()
    by_type = db.execute(
        "SELECT type, COUNT(*) as cnt FROM peers GROUP BY type"
    ).fetchall()

    return jsonify({
        "total_range": total_range,
        "used": used,
        "available": total_range - used,
        "by_status": {r["status"]: r["cnt"] for r in by_status},
        "by_type": {r["type"]: r["cnt"] for r in by_type},
    })


# =============================================================================
# API: Monitoring
# =============================================================================


@app.route("/api/monitoring/data", methods=["GET"])
@auth_required_or_local
def monitoring_data():
    """Return current monitoring data from scripts/monitor/vpn-output/data.json."""
    if not MONITOR_DATA_PATH.is_file():
        return jsonify({"error": "Monitoring data not available", "path": str(MONITOR_DATA_PATH)}), 404
    try:
        data = json.loads(MONITOR_DATA_PATH.read_text(encoding="utf-8"))
        return jsonify(data)
    except (json.JSONDecodeError, OSError) as exc:
        return jsonify({"error": f"Failed to read monitoring data: {exc}"}), 500


@app.route("/api/monitoring/peers", methods=["GET"])
@auth_required_or_local
def monitoring_peers():
    """Get active peers with handshake times and traffic from VPS1 via SSH."""
    dump_cmd = (
        "sudo -n awg show awg1 dump 2>/dev/null || "
        "sudo -n wg show awg1 dump 2>/dev/null || "
        "awg show awg1 dump 2>/dev/null || "
        "wg show awg1 dump 2>/dev/null"
    )
    try:
        dump = _vps1_ssh(dump_cmd)
    except Exception as exc:
        log.warning("monitoring/peers SSH failed: %s (check VPS1_IP, VPS1_KEY in .env)", exc)
        return jsonify({"error": f"SSH failed: {exc}"}), 502

    peers_data: list[dict] = []
    for line in dump.strip().splitlines():
        parts = _split_wg_dump_line(line)
        if len(parts) < 7:
            continue
        pub_key = parts[0]
        preshared = parts[1]
        endpoint = parts[2]
        allowed_ips = parts[3]
        peer_ip = _extract_peer_ip(allowed_ips)
        try:
            latest_handshake = int(parts[4]) if len(parts) > 4 and parts[4] and parts[4] != "0" else 0
        except (ValueError, TypeError):
            latest_handshake = 0
        try:
            rx_bytes = int(parts[5]) if len(parts) > 5 and parts[5] else 0
        except (ValueError, TypeError):
            rx_bytes = 0
        try:
            tx_bytes = int(parts[6]) if len(parts) > 6 and parts[6] else 0
        except (ValueError, TypeError):
            tx_bytes = 0
        keepalive = parts[7] if len(parts) > 7 else ""

        handshake_age = None
        if latest_handshake > 0:
            handshake_age = int(time.time()) - latest_handshake

        peers_data.append({
            "public_key": pub_key,
            "endpoint": endpoint,
            "allowed_ips": allowed_ips,
            "peer_ip": peer_ip,
            "latest_handshake": latest_handshake,
            "handshake_age_sec": handshake_age,
            "rx_bytes": rx_bytes,
            "tx_bytes": tx_bytes,
            "persistent_keepalive": keepalive,
        })

    return jsonify(peers_data)


# WebSocket: real-time monitoring
_monitor_thread: threading.Thread | None = None
_monitor_stop = threading.Event()


def _monitor_loop() -> None:
    """Background thread that emits monitoring data every 5 seconds."""
    while not _monitor_stop.is_set():
        try:
            if MONITOR_DATA_PATH.is_file():
                data = json.loads(MONITOR_DATA_PATH.read_text(encoding="utf-8"))
                socketio.emit("monitoring_update", data, namespace="/")
        except Exception as exc:
            log.debug("Monitor emit error: %s", exc)
        _monitor_stop.wait(5)


@socketio.on("connect")
def _ws_connect():
    global _monitor_thread
    if _monitor_thread is None or not _monitor_thread.is_alive():
        _monitor_stop.clear()
        _monitor_thread = threading.Thread(target=_monitor_loop, daemon=True)
        _monitor_thread.start()
        log.info("WebSocket monitor thread started")


@socketio.on("disconnect")
def _ws_disconnect():
    pass


# =============================================================================
# API: Settings
# =============================================================================


@app.route("/api/settings", methods=["GET"])
@auth_required
def settings_get():
    """Return all VPN settings."""
    db = get_db()
    return jsonify(_get_all_settings(db))


@app.route("/api/settings", methods=["PUT"])
@auth_required
def settings_update():
    """Update VPN settings (DNS, MTU, Jc, Jmin, Jmax, S1, S2, etc.)."""
    data = request.get_json(silent=True) or {}
    if not data:
        return jsonify({"error": "No settings provided"}), 400

    db = get_db()
    allowed_keys = {"DNS", "MTU", "Jc", "Jmin", "Jmax", "S1", "S2", "H1", "H2", "H3", "H4"}
    updated: dict[str, str] = {}

    for key, value in data.items():
        if key not in allowed_keys:
            continue
        db.execute(
            "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
            (key, str(value)),
        )
        updated[key] = str(value)

    db.commit()
    audit("settings_updated", "", updated)
    return jsonify(_get_all_settings(db))


# =============================================================================
# API: Audit
# =============================================================================


@app.route("/api/audit", methods=["GET"])
@auth_required
def audit_list():
    """Return audit log with pagination."""
    page = max(1, int(request.args.get("page", 1)))
    per_page = min(200, max(1, int(request.args.get("per_page", 50))))
    offset = (page - 1) * per_page

    db = get_db()
    conditions: list[str] = []
    params: list[Any] = []

    action_filter = request.args.get("action")
    if action_filter:
        conditions.append("action = ?")
        params.append(action_filter)

    user_filter = request.args.get("user_id")
    if user_filter:
        conditions.append("user_id = ?")
        params.append(int(user_filter))

    where = " WHERE " + " AND ".join(conditions) if conditions else ""

    total = db.execute(
        f"SELECT COUNT(*) FROM audit_log{where}", params
    ).fetchone()[0]

    rows = db.execute(
        f"SELECT * FROM audit_log{where} ORDER BY id DESC LIMIT ? OFFSET ?",
        params + [per_page, offset],
    ).fetchall()

    return jsonify({
        "items": [dict(r) for r in rows],
        "total": total,
        "page": page,
        "per_page": per_page,
        "pages": (total + per_page - 1) // per_page,
    })


# =============================================================================
# Frontend (admin panel UI)
# =============================================================================


@app.route("/")
@app.route("/admin.html")
def serve_admin_ui():
    """Serve the admin panel single-page app."""
    return send_from_directory(SCRIPT_DIR, "admin.html")


# =============================================================================
# Health check
# =============================================================================


@app.route("/api/health", methods=["GET"])
def health():
    """Simple health check endpoint (no auth required)."""
    return jsonify({
        "status": "ok",
        "version": "1.0.0",
        "timestamp": dt.datetime.now(dt.timezone.utc).isoformat(),
    })


# =============================================================================
# Error handlers
# =============================================================================


@app.errorhandler(404)
def _not_found(_e):
    return jsonify({"error": "Not found"}), 404


@app.errorhandler(500)
def _internal_error(_e):
    return jsonify({"error": "Internal server error"}), 500


# =============================================================================
# Main
# =============================================================================


def main() -> None:
    parser = argparse.ArgumentParser(description="AmneziaWG VPN Admin Panel API")
    parser.add_argument("--prod", action="store_true", help="Run in production mode (0.0.0.0:8443)")
    parser.add_argument("--host", default=None, help="Bind host")
    parser.add_argument("--port", type=int, default=None, help="Bind port")
    parser.add_argument("--cert", default=None, help="SSL certificate file (prod)")
    parser.add_argument("--key", default=None, help="SSL key file (prod)")
    args = parser.parse_args()

    startup_env = load_env()
    secret = (os.environ.get("ADMIN_SECRET_KEY") or startup_env.get("ADMIN_SECRET_KEY", "")).strip()
    if args.prod and not secret:
        log.error("ADMIN_SECRET_KEY is required in production mode")
        sys.exit(2)

    app.config["SECRET_KEY"] = secret or app.config["SECRET_KEY"]

    init_db()
    _ensure_default_admin()
    _load_default_settings()
    _import_peers_from_json()

    host = args.host or ("0.0.0.0" if args.prod else "127.0.0.1")
    port = args.port or (8443 if args.prod else 8081)

    log.info("Starting admin server on %s:%d (prod=%s)", host, port, args.prod)
    log.info("Admin panel UI: http://%s:%d/", "localhost" if host == "127.0.0.1" else host, port)

    cors_origins = _resolve_cors_origins(args.prod)
    CORS(app, resources={r"/api/*": {"origins": cors_origins}}, supports_credentials=True)
    socketio.server_options["cors_allowed_origins"] = cors_origins
    log.info("CORS allowlist: %s", cors_origins if cors_origins else "none")

    ssl_context = None
    if args.prod and args.cert and args.key:
        ssl_context = (args.cert, args.key)
        log.info("HTTPS enabled with cert=%s", args.cert)

    if args.prod:
        app.config["SESSION_COOKIE_SECURE"] = True

    # use_reloader=False in dev so SECRET_KEY is the same for all requests (no child process)
    socketio.run(
        app,
        host=host,
        port=port,
        debug=not args.prod,
        use_reloader=False,
        allow_unsafe_werkzeug=not args.prod,
        ssl_context=ssl_context,
    )


if __name__ == "__main__":
    main()
