#!/usr/bin/env bash
# =============================================================================
# run-bot.sh — локальный запуск Telegram bot service (FastAPI)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_DIR="${PROJECT_ROOT}/backend"
VENV_DIR="${BACKEND_DIR}/.venv"
REQUIREMENTS="${BACKEND_DIR}/requirements.txt"

cd "$PROJECT_ROOT"

find_python() {
    for cmd in python3 python py; do
        if command -v "$cmd" &>/dev/null; then
            printf "%s" "$cmd"
            return 0
        fi
    done
    return 1
}

PYTHON="$(find_python)" || { echo "Python 3 не найден"; exit 1; }

if [[ ! -d "$VENV_DIR" ]]; then
    echo "Создание venv: $VENV_DIR"
    "$PYTHON" -m venv "$VENV_DIR"
fi

if [[ -f "$VENV_DIR/bin/activate" ]]; then
    source "$VENV_DIR/bin/activate"
    VENV_PYTHON="$VENV_DIR/bin/python"
elif [[ -f "$VENV_DIR/Scripts/activate" ]]; then
    source "$VENV_DIR/Scripts/activate"
    VENV_PYTHON="$VENV_DIR/Scripts/python.exe"
else
    echo "Не найден activate в $VENV_DIR"
    exit 1
fi

"$VENV_PYTHON" -m pip install -q -r "$REQUIREMENTS"

PORT="${BOT_SERVICE_PORT:-8010}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="${2:-8010}"; shift 2 ;;
        *) shift ;;
    esac
done

exec "$VENV_PYTHON" -m uvicorn backend.bot.main:app --host 0.0.0.0 --port "$PORT" --reload
