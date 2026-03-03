#!/usr/bin/env bash
# Миграция admin.db + peers.json → Postgres
# Idempotent. Требует: Postgres, alembic upgrade head, DATABASE_URL.
# Usage: bash scripts/migrate_to_pg.sh [--dry-run]

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_ROOT"

export PYTHONPATH="$PROJECT_ROOT"
PYTHON=""
if [[ -f "${PROJECT_ROOT}/backend/.venv/Scripts/python.exe" ]]; then
  PYTHON="${PROJECT_ROOT}/backend/.venv/Scripts/python.exe"
elif [[ -f "${PROJECT_ROOT}/backend/.venv/bin/python" ]]; then
  PYTHON="${PROJECT_ROOT}/backend/.venv/bin/python"
else
  for cmd in python3 python py; do
    if command -v "$cmd" >/dev/null 2>&1; then
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
  "$PYTHON" -m pip install -q -r "${PROJECT_ROOT}/backend/requirements.txt"
fi

"$PYTHON" -m scripts.migrate.migrate_to_pg "$@"
