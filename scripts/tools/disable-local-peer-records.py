#!/usr/bin/env python3
"""Disable/remove local peer records by public key.

This prevents admin-server startup sync from re-adding stale server peers.
"""

from __future__ import annotations

import json
import shutil
import sqlite3
import sys
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DB_PATH = ROOT / "scripts" / "admin" / "admin.db"
PEERS_JSON = ROOT / "vpn-output" / "peers.json"


def backup(path: Path) -> Path | None:
    if not path.exists():
        return None
    dst = path.with_suffix(path.suffix + f".bak.{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(path, dst)
    return dst


def main(argv: list[str]) -> int:
    keys = [x.strip() for x in argv[1:] if x.strip()]
    if not keys:
        print("Usage: disable-local-peer-records.py PUBLIC_KEY [PUBLIC_KEY ...]", file=sys.stderr)
        return 2

    backups: list[Path] = []
    db_disabled = 0
    json_removed = 0

    if DB_PATH.exists():
        b = backup(DB_PATH)
        if b:
            backups.append(b)
        con = sqlite3.connect(DB_PATH)
        try:
            for key in keys:
                cur = con.execute(
                    "UPDATE peers SET status = 'disabled', updated_at = datetime('now') WHERE public_key = ?",
                    (key,),
                )
                db_disabled += cur.rowcount
            con.commit()
        finally:
            con.close()

    if PEERS_JSON.exists():
        b = backup(PEERS_JSON)
        if b:
            backups.append(b)
        data = json.loads(PEERS_JSON.read_text(encoding="utf-8"))
        filtered = [p for p in data if p.get("public_key") not in set(keys)]
        json_removed = len(data) - len(filtered)
        tmp = PEERS_JSON.with_suffix(".tmp")
        tmp.write_text(json.dumps(filtered, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
        tmp.replace(PEERS_JSON)

    for path in backups:
        print(f"backup={path}")
    print(f"db_disabled={db_disabled}")
    print(f"peers_json_removed={json_removed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
