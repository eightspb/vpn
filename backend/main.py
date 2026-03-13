"""FastAPI entry point — новый модульный backend."""

from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response

from backend import __version__
from backend.api.routes.admin_compat import router as admin_compat_router
from backend.api.routes.health import router as health_router
from backend.api.routes.v1.admin import router as admin_router
from backend.api.routes.v1.meta import router as meta_router
from backend.api.routes.v1.peers_monitoring import router as peers_monitoring_router
from backend.core.config import get_settings


class SecurityHeadersMiddleware(BaseHTTPMiddleware):
    """Middleware to add security headers to all responses."""

    async def dispatch(self, request: Request, call_next) -> Response:
        response = await call_next(request)

        # Security headers
        response.headers["X-Content-Type-Options"] = "nosniff"
        response.headers["X-Frame-Options"] = "DENY"
        response.headers["X-XSS-Protection"] = "1; mode=block"
        response.headers["Referrer-Policy"] = "strict-origin-when-cross-origin"
        response.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self'"

        # HSTS only in production (not in development)
        settings = get_settings()
        if settings.APP_ENV != "development":
            response.headers["Strict-Transport-Security"] = "max-age=31536000; includeSubDomains"

        return response


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

    # Security headers middleware
    app.add_middleware(SecurityHeadersMiddleware)

    # CORS configuration
    cors_origins = [o.strip() for o in settings.CORS_ALLOWED_ORIGINS.split(",") if o.strip()]
    if cors_origins:
        app.add_middleware(
            CORSMiddleware,
            allow_origins=cors_origins,
            allow_credentials=True,
            allow_methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
            allow_headers=["*"],
        )

    # Health endpoints (root)
    app.include_router(health_router)

    # API v1
    app.include_router(meta_router, prefix="/api/v1")
    app.include_router(admin_router, prefix="/api/v1")
    app.include_router(peers_monitoring_router, prefix="/api/v1")

    # Compatibility routes for existing admin.html
    app.include_router(admin_compat_router)

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
