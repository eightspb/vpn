"""Отдельный FastAPI сервис для Telegram Bot MVP."""

from contextlib import asynccontextmanager
import logging
from typing import Any

from fastapi import FastAPI, Header, HTTPException, Query, Request

from backend.core.config import get_settings
from backend.db.session import get_session
from backend.services.bot_service import build_bot_service

logger = logging.getLogger(__name__)
settings = get_settings()
bot_service = build_bot_service()


@asynccontextmanager
async def lifespan(app: FastAPI):
    logger.info("telegram bot service started")
    yield
    logger.info("telegram bot service stopped")


app = FastAPI(
    title="VPN Telegram Bot",
    version="0.1.0",
    lifespan=lifespan,
)


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/webhook/telegram")
async def telegram_webhook(
    request: Request,
    x_telegram_bot_api_secret_token: str | None = Header(default=None),
) -> dict[str, bool]:
    if settings.TELEGRAM_WEBHOOK_SECRET_TOKEN:
        if x_telegram_bot_api_secret_token != settings.TELEGRAM_WEBHOOK_SECRET_TOKEN:
            raise HTTPException(status_code=403, detail="invalid webhook secret")
    payload: dict[str, Any] = await request.json()
    with get_session() as session:
        bot_service.process_update(
            session=session,
            update=payload,
            ip_address=request.client.host if request.client else None,
        )
    return {"ok": True}


@app.post("/payments/test/webhook")
async def test_payment_webhook(
    request: Request,
    x_test_payment_secret: str | None = Header(default=None),
) -> dict[str, bool]:
    if settings.TEST_PAYMENT_WEBHOOK_SECRET and x_test_payment_secret != settings.TEST_PAYMENT_WEBHOOK_SECRET:
        raise HTTPException(status_code=403, detail="invalid payment secret")
    payload: dict[str, Any] = await request.json()
    external_id = str(payload.get("external_id") or "").strip()
    if not external_id:
        raise HTTPException(status_code=400, detail="external_id required")
    with get_session() as session:
        found = bot_service.confirm_payment(
            session=session,
            external_id=external_id,
            ip_address=request.client.host if request.client else None,
            source="payment_webhook",
        )
    if not found:
        raise HTTPException(status_code=404, detail="payment not found")
    return {"ok": True}


@app.post("/payments/test/confirm/{external_id}")
def internal_confirm_payment(external_id: str, token: str | None = None) -> dict[str, bool]:
    if settings.BOT_INTERNAL_API_TOKEN and token != settings.BOT_INTERNAL_API_TOKEN:
        raise HTTPException(status_code=403, detail="invalid internal token")
    with get_session() as session:
        found = bot_service.confirm_payment(
            session=session,
            external_id=external_id,
            ip_address=None,
            source="internal_confirm",
        )
    if not found:
        raise HTTPException(status_code=404, detail="payment not found")
    return {"ok": True}


def _require_internal_token(token: str | None, header_token: str | None) -> None:
    expected = settings.BOT_INTERNAL_API_TOKEN
    provided = (header_token or token or "").strip()
    if expected and provided != expected:
        raise HTTPException(status_code=403, detail="invalid internal token")


@app.get("/admin/bot/overview")
def admin_bot_overview(
    token: str | None = Query(default=None),
    x_bot_internal_token: str | None = Header(default=None),
) -> dict[str, Any]:
    _require_internal_token(token=token, header_token=x_bot_internal_token)
    with get_session() as session:
        return bot_service.get_admin_overview(session)


@app.get("/admin/bot/activity")
def admin_bot_activity(
    limit: int = Query(default=50, ge=1, le=500),
    action: str | None = Query(default=None),
    token: str | None = Query(default=None),
    x_bot_internal_token: str | None = Header(default=None),
) -> dict[str, Any]:
    _require_internal_token(token=token, header_token=x_bot_internal_token)
    with get_session() as session:
        items = bot_service.get_admin_activity(session, limit=limit, action=action)
    return {"items": items, "total": len(items)}


@app.get("/admin/bot/settings")
def admin_bot_settings(
    token: str | None = Query(default=None),
    x_bot_internal_token: str | None = Header(default=None),
) -> dict[str, Any]:
    _require_internal_token(token=token, header_token=x_bot_internal_token)
    with get_session() as session:
        values = bot_service.get_admin_settings(session)
    return {"items": values}


@app.put("/admin/bot/settings")
async def admin_bot_settings_update(
    request: Request,
    token: str | None = Query(default=None),
    x_bot_internal_token: str | None = Header(default=None),
) -> dict[str, Any]:
    _require_internal_token(token=token, header_token=x_bot_internal_token)
    payload: dict[str, Any] = await request.json()
    with get_session() as session:
        values = bot_service.update_admin_settings(
            session=session,
            values=payload,
            ip_address=request.client.host if request.client else None,
        )
    return {"items": values}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "backend.bot.main:app",
        host=settings.BOT_SERVICE_HOST,
        port=settings.BOT_SERVICE_PORT,
        reload=settings.APP_ENV == "development",
    )
