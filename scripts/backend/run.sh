#!/usr/bin/env bash
# =============================================================================
# run.sh — локальный запуск нового FastAPI backend
#
# Использование:
#   bash scripts/backend/run.sh
#   bash scripts/backend/run.sh --port 9000
#
# Требует: Python 3.10+, backend/requirements.txt
# .env в корне проекта (или backend/.env) для конфигурации.
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
            local ver
            ver="$("$cmd" --version 2>&1 | grep -oP '\d+\.\d+' | head -1)"
            [[ "${ver%%.*}" -ge 3 ]] && printf "%s" "$cmd" && return 0
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

if ! "$VENV_PYTHON" -m pip install -q -r "$REQUIREMENTS"; then
    echo "Не удалось установить зависимости backend"
    exit 1
fi

PORT=8000
while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="${2:-8000}"; shift 2 ;;
        *) shift ;;
    esac
done

exec "$VENV_PYTHON" -m uvicorn backend.main:app --host 0.0.0.0 --port "$PORT" --reload
