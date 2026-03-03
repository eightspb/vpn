"""Сервис аудита доменных событий."""

import json
from typing import Any, Optional

from sqlalchemy.orm import Session

from backend.models.audit_log import AuditLog


def write_audit_event(
    session: Session,
    action: str,
    user_id: Optional[int],
    target: Optional[str] = None,
    details: Optional[dict[str, Any]] = None,
    ip_address: Optional[str] = None,
) -> None:
    """Записывает audit-событие в БД."""
    payload = None
    if details is not None:
        payload = json.dumps(details, ensure_ascii=False, sort_keys=True)
    session.add(
        AuditLog(
            user_id=user_id,
            action=action,
            target=target,
            details=payload,
            ip_address=ip_address,
        )
    )
