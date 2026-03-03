#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "[stage5] checking worker entrypoint"
test -f backend/workers/main.py
if command -v rg >/dev/null 2>&1; then
  rg -n "WorkerScheduler|APScheduler|deliver_notifications|notify_expiring_3d|notify_expiring_1d|notify_expired|cleanup_stale|sync_subscription_states" backend/workers/scheduler.py > /dev/null
else
  grep -nE "WorkerScheduler|deliver_notifications|notify_expiring_3d|notify_expiring_1d|notify_expired|cleanup_stale|sync_subscription_states" backend/workers/scheduler.py > /dev/null
fi

echo "[stage5] checking notification models and migration"
test -f backend/models/notifications.py
if command -v rg >/dev/null 2>&1; then
  rg -n "notification_events|broadcast_campaigns|worker_job_runs|worker_dead_letters" alembic/versions/007_stage5_workers_notifications.py > /dev/null
else
  grep -nE "notification_events|broadcast_campaigns|worker_job_runs|worker_dead_letters" alembic/versions/007_stage5_workers_notifications.py > /dev/null
fi

echo "[stage5] checking admin API endpoints"
if command -v rg >/dev/null 2>&1; then
  rg -n "/broadcasts|/workers/runs|/workers/dlq" backend/api/routes/v1/admin.py > /dev/null
else
  grep -nE "/broadcasts|/workers/runs|/workers/dlq" backend/api/routes/v1/admin.py > /dev/null
fi

echo "[stage5] checking compose and requirements"
if command -v rg >/dev/null 2>&1; then
  rg -n "apscheduler" backend/requirements.txt > /dev/null
  rg -n "worker:" docker-compose.backend.yml > /dev/null
else
  grep -nE "apscheduler" backend/requirements.txt > /dev/null
  grep -nE "worker:" docker-compose.backend.yml > /dev/null
fi

echo "[stage5] PASS"
