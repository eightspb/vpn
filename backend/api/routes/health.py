"""Health check endpoints — /health, /ready."""

from fastapi import APIRouter

router = APIRouter(tags=["health"])


@router.get("/health")
def health() -> dict:
    """Базовый health check — приложение запущено."""
    return {"status": "ok"}


@router.get("/ready")
def ready() -> dict:
    """Readiness probe — приложение готово принимать трафик."""
    return {"status": "ready"}
