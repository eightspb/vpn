"""Meta endpoint — версия, окружение."""

from fastapi import APIRouter

from backend import __version__
from backend.core.config import get_settings

router = APIRouter(prefix="/meta", tags=["meta"])


@router.get("")
def meta() -> dict:
    """Информация о приложении: версия, окружение."""
    settings = get_settings()
    return {
        "version": __version__,
        "env": settings.APP_ENV,
    }
