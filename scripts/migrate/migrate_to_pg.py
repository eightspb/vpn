#!/usr/bin/env python3
"""
Миграция данных из scripts/admin/admin.db и vpn-output/peers.json в Postgres.

Idempotent: повторный запуск не создаёт дубли (проверка по username, source_id, key).

Usage:
    python -m scripts.migrate.migrate_to_pg [--dry-run] [--admin-db PATH] [--peers-json PATH]
    или через scripts/migrate_to_pg.sh

Требуется:
    - Postgres запущен, alembic upgrade head выполнен
    - DATABASE_URL в .env
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import sqlite3
import sys
from collections.abc import Generator
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

# Добавляем корень проекта в PYTHONPATH
PROJECT_ROOT = Path(__file__).resolve().parent.parent.parent
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

from dotenv import load_dotenv

# Explicitly prefer project .env for deterministic migrations.
load_dotenv(PROJECT_ROOT / ".env", override=True)

from sqlalchemy.orm import Session

# Локальный импорт после path
from backend.db.session import get_session_factory
from backend.models import (
    AuditLog,
    PeerDevice,
    Setting,
    User,
)
from backend.models.enums import RoleEnum

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
log = logging.getLogger("migrate")


@dataclass
class MigrationReport:
    """Отчёт валидации миграции."""

    users_before: int = 0
    users_after: int = 0
    peers_before: int = 0
    peers_after: int = 0
    users_imported: int = 0
    users_skipped: int = 0
    peers_imported: int = 0
    peers_skipped: int = 0
    settings_imported: int = 0
    audit_log_imported: int = 0
    failed: list[str] = field(default_factory=list)
    dry_run: bool = False


def _parse_datetime(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        # SQLite stores datetime as 'YYYY-MM-DD HH:MM:SS'
        if "T" in (s or ""):
            return datetime.fromisoformat(s.replace("Z", "+00:00"))
        return datetime.strptime(s, "%Y-%m-%d %H:%M:%S").replace(tzinfo=timezone.utc)
    except (ValueError, TypeError):
        return None


def _iter_users_sqlite(conn: sqlite3.Connection) -> Generator[dict, None, None]:
    for row in conn.execute(
        "SELECT id, username, password_hash, created_at, last_login FROM users"
    ).fetchall():
        yield {
            "id": row[0],
            "username": row[1],
            "password_hash": row[2],
            "created_at": row[3],
            "last_login": row[4],
        }


def _iter_peers_sqlite(conn: sqlite3.Connection) -> Generator[dict, None, None]:
    for row in conn.execute(
        """SELECT id, name, ip, type, public_key, private_key, config_file, status, created_at
           FROM peers"""
    ).fetchall():
        yield {
            "id": row[0],
            "name": row[1],
            "ip": row[2],
            "type": row[3] or "phone",
            "public_key": row[4],
            "private_key": row[5],
            "config_file": row[6],
            "status": row[7] or "active",
            "created_at": row[8],
        }


def _iter_settings_sqlite(conn: sqlite3.Connection) -> Generator[tuple[str, str | None], None, None]:
    for row in conn.execute("SELECT key, value FROM settings").fetchall():
        yield (row[0], row[1])


def _iter_audit_sqlite(conn: sqlite3.Connection) -> Generator[dict, None, None]:
    for row in conn.execute(
        "SELECT user_id, action, target, details, created_at, ip_address FROM audit_log"
    ).fetchall():
        yield {
            "user_id": row[0],
            "action": row[1],
            "target": row[2],
            "details": row[3],
            "created_at": row[4],
            "ip_address": row[5],
        }


def migrate_users(session: Session, admin_db: Path, report: MigrationReport) -> None:
    """Миграция users из admin.db (idempotent по username)."""
    if not admin_db.is_file():
        log.warning("admin.db не найден: %s", admin_db)
        return

    conn = sqlite3.connect(str(admin_db))
    conn.row_factory = sqlite3.Row

    count_before = conn.execute("SELECT COUNT(*) FROM users").fetchone()[0]
    report.users_before = count_before

    from sqlalchemy import select

    existing = set(r[0] for r in session.execute(select(User.username)).fetchall())

    imported = 0
    skipped = 0
    for u in _iter_users_sqlite(conn):
        if u["username"] in existing:
            skipped += 1
            continue
        if report.dry_run:
            imported += 1
            continue
        role = RoleEnum.ADMIN if u["username"] == "admin" else RoleEnum.USER
        user = User(
            username=u["username"],
            password_hash=u["password_hash"],
            role=role,
            created_at=_parse_datetime(u["created_at"]) or datetime.now(timezone.utc),
            last_login=_parse_datetime(u["last_login"]),
        )
        session.add(user)
        session.flush()
        imported += 1
        existing.add(u["username"])

    conn.close()
    report.users_imported = imported
    report.users_skipped = skipped
    report.users_after = report.users_before  # approximate; actual = existing + imported


def migrate_peers_from_sqlite(
    session: Session, admin_db: Path, report: MigrationReport
) -> None:
    """Миграция peers из admin.db в peers_devices (idempotent по source_id)."""
    if not admin_db.is_file():
        return

    conn = sqlite3.connect(str(admin_db))
    count_before = conn.execute("SELECT COUNT(*) FROM peers").fetchone()[0]
    report.peers_before = count_before

    from sqlalchemy import select
    existing_source_ids = set(
        r[0]
        for r in session.execute(select(PeerDevice.source_id))
        .fetchall()
        if r[0] is not None
    )

    imported = 0
    skipped = 0
    for p in _iter_peers_sqlite(conn):
        source_id = f"sqlite:{p['id']}"
        if source_id in existing_source_ids:
            skipped += 1
            continue
        if report.dry_run:
            imported += 1
            continue
        try:
            pd = PeerDevice(
                name=p["name"],
                ip=p["ip"],
                type=p["type"],
                public_key=p["public_key"] or None,
                private_key=p["private_key"] or None,
                config_file=p["config_file"] or None,
                status=p["status"],
                source_id=source_id,
                created_at=_parse_datetime(p["created_at"]) or datetime.now(timezone.utc),
            )
            session.add(pd)
            session.flush()
            imported += 1
            existing_source_ids.add(source_id)
        except Exception as e:
            report.failed.append(f"peer sqlite:{p['id']} ({p.get('ip', '')}): {e}")

    conn.close()
    report.peers_imported += imported
    report.peers_skipped += skipped


def migrate_peers_from_json(
    session: Session, peers_path: Path, report: MigrationReport
) -> None:
    """Миграция peers из peers.json (idempotent по source_id = json:ip)."""
    if not peers_path.is_file():
        log.warning("peers.json не найден: %s", peers_path)
        return

    try:
        data = json.loads(peers_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as e:
        log.warning("Не удалось прочитать peers.json: %s", e)
        return

    if not isinstance(data, list):
        report.failed.append("peers.json: ожидается JSON-массив")
        return

    from sqlalchemy import select
    existing_source_ids = set(
        r[0]
        for r in session.execute(select(PeerDevice.source_id))
        .fetchall()
        if r[0] is not None
    )
    existing_ips = set(
        r[0] for r in session.execute(select(PeerDevice.ip)).fetchall()
    )

    imported = 0
    skipped = 0
    for i, p in enumerate(data):
        ip = p.get("ip", "")
        if not ip:
            report.failed.append(f"peers.json[{i}]: отсутствует ip")
            continue
        source_id = f"json:{ip}"
        if source_id in existing_source_ids or ip in existing_ips:
            skipped += 1
            continue
        if report.dry_run:
            imported += 1
            continue
        try:
            created = p.get("created", "")
            pd = PeerDevice(
                name=p.get("name", "unknown"),
                ip=ip,
                type=p.get("type", "phone"),
                public_key=p.get("public_key") or None,
                private_key=p.get("private_key") or None,
                config_file=p.get("config_file") or None,
                status="active",
                source_id=source_id,
                created_at=_parse_datetime(created) if created else datetime.now(timezone.utc),
            )
            session.add(pd)
            session.flush()
            imported += 1
            existing_source_ids.add(source_id)
            existing_ips.add(ip)
        except Exception as e:
            report.failed.append(f"peer json:{ip}: {e}")

    report.peers_imported += imported
    report.peers_skipped += skipped
    if report.peers_before == 0 and data:
        report.peers_before = len(data)


def migrate_settings(session: Session, admin_db: Path, report: MigrationReport) -> None:
    """Миграция settings (idempotent по key)."""
    if not admin_db.is_file():
        return

    conn = sqlite3.connect(str(admin_db))
    from sqlalchemy import select

    existing_keys = set(
        r[0] for r in session.execute(select(Setting.key)).fetchall()
    )

    imported = 0
    for key, value in _iter_settings_sqlite(conn):
        if key in existing_keys:
            continue
        if report.dry_run:
            imported += 1
            continue
        session.add(Setting(key=key, value=value))
        imported += 1
        existing_keys.add(key)

    conn.close()
    report.settings_imported = imported


def migrate_audit_log(session: Session, admin_db: Path, report: MigrationReport) -> None:
    """Миграция audit_log. Идемпотентность: только если PG.audit_log пуст."""
    if not admin_db.is_file():
        return

    from sqlalchemy import func, select

    count = session.execute(select(func.count(AuditLog.id))).scalar() or 0
    if count > 0:
        log.info("audit_log уже содержит записи, пропуск миграции для идемпотентности")
        return

    conn = sqlite3.connect(str(admin_db))
    imported = 0
    for a in _iter_audit_sqlite(conn):
        if report.dry_run:
            imported += 1
            continue
        try:
            al = AuditLog(
                user_id=a["user_id"],
                action=a["action"],
                target=a["target"],
                details=a["details"],
                created_at=_parse_datetime(a["created_at"]) or datetime.now(timezone.utc),
                ip_address=a["ip_address"],
            )
            session.add(al)
            imported += 1
        except Exception as e:
            report.failed.append(f"audit_log: {e}")

    conn.close()
    report.audit_log_imported = imported


def run_migration(
    admin_db: Path | None = None,
    peers_json: Path | None = None,
    dry_run: bool = False,
) -> MigrationReport:
    """Выполнить миграцию. Idempotent."""
    report = MigrationReport(dry_run=dry_run)
    project = PROJECT_ROOT

    admin_db = admin_db or project / "scripts" / "admin" / "admin.db"
    peers_json = peers_json or project / "vpn-output" / "peers.json"

    db_url = os.environ.get("DATABASE_URL")
    if not db_url:
        report.failed.append("DATABASE_URL не задан")
        return report

    SessionLocal = get_session_factory()
    session = SessionLocal()
    try:
        migrate_users(session, admin_db, report)
        migrate_peers_from_sqlite(session, admin_db, report)
        migrate_peers_from_json(session, peers_json, report)
        migrate_settings(session, admin_db, report)
        migrate_audit_log(session, admin_db, report)

        if not dry_run:
            from sqlalchemy import func, select
            session.commit()
            report.users_after = session.execute(select(func.count(User.id))).scalar() or 0
            report.peers_after = session.execute(select(func.count(PeerDevice.id))).scalar() or 0
    except Exception as e:
        session.rollback()
        report.failed.append(str(e))
        log.exception("Миграция прервана: %s", e)
    finally:
        session.close()

    return report


def print_report(report: MigrationReport) -> None:
    """Вывод валидационного отчёта."""
    print("\n" + "=" * 60)
    print("ОТЧЁТ ВАЛИДАЦИИ МИГРАЦИИ")
    print("=" * 60)
    print(f"  Пользователи:  до={report.users_before}  после={report.users_after}")
    print(f"  Пиров:         до={report.peers_before}  после={report.peers_after}")
    print(f"  Импортировано: users={report.users_imported}, peers={report.peers_imported}")
    print(f"  Пропущено:     users={report.users_skipped}, peers={report.peers_skipped}")
    print(f"  Settings:      {report.settings_imported}")
    print(f"  Audit log:     {report.audit_log_imported}")
    if report.failed:
        print("\n  Не удалось перенести:")
        for f in report.failed:
            print(f"    - {f}")
    print("=" * 60 + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="Миграция admin.db + peers.json → Postgres")
    parser.add_argument("--dry-run", action="store_true", help="Только отчёт, без записи")
    parser.add_argument("--admin-db", type=Path, help="Путь к admin.db")
    parser.add_argument("--peers-json", type=Path, help="Путь к peers.json")
    args = parser.parse_args()

    report = run_migration(
        admin_db=args.admin_db,
        peers_json=args.peers_json,
        dry_run=args.dry_run,
    )

    print_report(report)
    return 1 if report.failed else 0


if __name__ == "__main__":
    sys.exit(main())
