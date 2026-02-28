#!/usr/bin/env python3
"""Verify admin user and password in admin.db. Run from repo root: python scripts/admin/verify-login.py"""
import sys
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
DB = SCRIPT_DIR / "admin.db"

def main():
    import sqlite3
    import bcrypt
    if not DB.is_file():
        print("DB not found:", DB)
        return 1
    conn = sqlite3.connect(str(DB))
    conn.row_factory = sqlite3.Row
    row = conn.execute("SELECT id, username, password_hash FROM users WHERE username = ?", ("admin",)).fetchone()
    conn.close()
    if not row:
        print("User 'admin' not in DB")
        return 1
    h = (row["password_hash"] or "").strip()
    ok = bcrypt.checkpw(b"admin", h.encode("utf-8"))
    print("Hash length:", len(h), "| checkpw(b'admin', hash):", ok)
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
