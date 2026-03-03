"""Worker job metrics and DLQ helpers."""

from __future__ import annotations

import json
from dataclasses import dataclass
from datetime import datetime
from typing import Any, Optional

from sqlalchemy.orm import Session

from backend.models import WorkerDeadLetter, WorkerJobRun


@dataclass
class JobCounters:
    processed: int = 0
    success: int = 0
    errors: int = 0


def save_job_run(
    session: Session,
    *,
    task_name: str,
    status: str,
    started_at: datetime,
    finished_at: datetime,
    counters: JobCounters,
    details: Optional[dict[str, Any]] = None,
    error_message: Optional[str] = None,
) -> WorkerJobRun:
    duration_ms = int((finished_at - started_at).total_seconds() * 1000)
    row = WorkerJobRun(
        task_name=task_name,
        status=status,
        started_at=started_at,
        finished_at=finished_at,
        duration_ms=max(0, duration_ms),
        processed_count=max(0, counters.processed),
        success_count=max(0, counters.success),
        error_count=max(0, counters.errors),
        details=json.dumps(details, ensure_ascii=False, sort_keys=True) if details else None,
        error_message=error_message,
    )
    session.add(row)
    return row


def push_dlq(
    session: Session,
    *,
    task_name: str,
    item_key: Optional[str],
    payload: Optional[dict[str, Any]],
    error_message: str,
    attempts: int,
) -> WorkerDeadLetter:
    row = WorkerDeadLetter(
        task_name=task_name,
        item_key=item_key,
        payload=json.dumps(payload, ensure_ascii=False, sort_keys=True) if payload else None,
        error_message=error_message,
        attempts=max(0, attempts),
    )
    session.add(row)
    return row
