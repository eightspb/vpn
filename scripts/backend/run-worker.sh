#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

if [[ -x "backend/.venv/Scripts/python.exe" ]]; then
  backend/.venv/Scripts/python.exe -m backend.workers.main
  exit 0
fi

if [[ -x "backend/.venv/bin/python" ]]; then
  backend/.venv/bin/python -m backend.workers.main
  exit 0
fi

python -m backend.workers.main
