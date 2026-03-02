#!/usr/bin/env python3
"""
Сброс пароля пользователя admin.
Вызов: python reset-admin-password.py <path-to-admin.db> [new-password]
Используется из deploy-admin.sh reset-password.
"""

import sys
import sqlite3

def main():
    if len(sys.argv) < 2:
        print("Usage: python reset-admin-password.py <admin.db path> [new-password]", file=sys.stderr)
        sys.exit(1)
    db_path = sys.argv[1]
    new_password = sys.argv[2] if len(sys.argv) > 2 else "My-secure-admin-password"

    try:
        import bcrypt
    except ImportError:
        print("Ошибка: установите bcrypt (pip install -r requirements.txt)", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(db_path)
    cur = conn.execute("SELECT id FROM users WHERE username = ?", ("admin",))
    row = cur.fetchone()
    if not row:
        print("Пользователь admin не найден в БД.", file=sys.stderr)
        conn.close()
        sys.exit(1)

    pw_hash = bcrypt.hashpw(new_password.encode("utf-8"), bcrypt.gensalt(rounds=12)).decode()
    conn.execute("UPDATE users SET password_hash = ? WHERE username = ?", (pw_hash, "admin"))
    conn.commit()
    conn.close()
    print(f"Пароль сброшен: логин admin, пароль {new_password}")


if __name__ == "__main__":
    main()
