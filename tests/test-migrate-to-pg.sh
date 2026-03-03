#!/usr/bin/env bash
# Тест миграции в Postgres: dry-run.
# Требует: Postgres, alembic upgrade head, DATABASE_URL. См. README «Миграция в Postgres».
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

export PYTHONPATH="$PROJECT_ROOT"
export DATABASE_URL="${DATABASE_URL:-postgresql+psycopg2://vpn:secret@localhost:5432/vpn}"

PYTHON=""
if [[ -f "${PROJECT_ROOT}/backend/.venv/Scripts/python.exe" ]]; then
    PYTHON="${PROJECT_ROOT}/backend/.venv/Scripts/python.exe"
elif [[ -f "${PROJECT_ROOT}/backend/.venv/bin/python" ]]; then
    PYTHON="${PROJECT_ROOT}/backend/.venv/bin/python"
else
    for cmd in python3 python py; do
        if command -v "$cmd" &>/dev/null; then
            PYTHON="$cmd"
            break
        fi
    done
fi

if [[ -z "$PYTHON" ]]; then
    echo "Python not found"
    exit 1
fi

# Ensure runtime deps exist for migration module.
if ! "$PYTHON" -c "import sqlalchemy, dotenv" >/dev/null 2>&1; then
    echo "Missing Python deps for migration test (need sqlalchemy + python-dotenv)."
    exit 1
fi

"$PYTHON" -m scripts.migrate.migrate_to_pg --dry-run
echo "=== migrate_to_pg dry-run OK ==="
