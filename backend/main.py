"""FastAPI entry point — новый модульный backend."""

from contextlib import asynccontextmanager

from fastapi import FastAPI

from backend import __version__
from backend.api.routes.health import router as health_router
from backend.api.routes.v1.meta import router as meta_router
from backend.core.config import get_settings


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Жизненный цикл приложения."""
    yield
    # Shutdown hooks при необходимости


def create_app() -> FastAPI:
    """Фабрика приложения."""
    settings = get_settings()
    app = FastAPI(
        title="VPN Backend",
        version=__version__,
        lifespan=lifespan,
    )

    # Health endpoints (root)
    app.include_router(health_router)

    # API v1
    app.include_router(meta_router, prefix="/api/v1")

    return app


app = create_app()


if __name__ == "__main__":
    import uvicorn

    settings = get_settings()
    uvicorn.run(
        "backend.main:app",
        host=settings.APP_HOST,
        port=settings.APP_PORT,
        reload=settings.APP_ENV == "development",
    )
