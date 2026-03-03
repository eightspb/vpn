"""Compatibility API for existing scripts/admin/admin.html endpoints."""

from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, Request, Response

from backend.api.routes.v1.admin import (
    ChangePasswordRequest,
    _db_session,
    LoginRequest,
    SettingsUpdateRequest,
    audit_list,
    change_password,
    get_current_user,
    login,
    logout,
    me,
    settings_get,
    settings_update,
)
from backend.api.routes.v1.peers_monitoring import (
    monitoring_data,
    monitoring_peers,
    peers_batch_create,
    peers_config,
    peers_config_by_ip,
    peers_create,
    peers_delete,
    peers_disable,
    peers_enable,
    peers_get,
    peers_import_by_ip,
    peers_list,
    peers_qr,
    peers_stats,
    peers_update,
)
from backend.db.session import get_session
from backend.services.bot_service import build_bot_service

router = APIRouter(prefix="/api", tags=["admin-compat"])

bot_service = build_bot_service()


@router.post("/auth/login")
def compat_login(
    payload: dict[str, Any],
    request: Request,
    response: Response,
    session=Depends(_db_session),
):
    request_model = LoginRequest(**payload)
    return login(payload=request_model, request=request, response=response, session=session)


@router.post("/auth/logout")
def compat_logout(
    request: Request,
    response: Response,
    user=Depends(get_current_user),
    session=Depends(_db_session),
):
    return logout(request=request, response=response, user=user, session=session)


@router.get("/auth/me")
def compat_me(user=Depends(get_current_user)):
    return me(user=user)


@router.post("/auth/change-password")
def compat_change_password(
    payload: dict[str, Any],
    request: Request,
    user=Depends(get_current_user),
    session=Depends(_db_session),
):
    request_model = ChangePasswordRequest(**payload)
    return change_password(payload=request_model, request=request, user=user, session=session)


@router.get("/settings")
def compat_settings_get(user=Depends(get_current_user), session=Depends(_db_session)):
    return settings_get(_=user, session=session).get("items", {})


@router.put("/settings")
def compat_settings_put(payload: dict[str, Any], request: Request, user=Depends(get_current_user), session=Depends(_db_session)):
    result = settings_update(
        payload=SettingsUpdateRequest(items=payload),
        request=request,
        actor=user,
        session=session,
    )
    return result.get("items", {})


@router.get("/audit")
def compat_audit(
    page: int = 1,
    per_page: int = 50,
    action: str | None = None,
    user=Depends(get_current_user),
    session=Depends(_db_session),
):
    return audit_list(page=page, per_page=per_page, action=action, _=user, session=session)


@router.get("/bot/overview")
def compat_bot_overview(user=Depends(get_current_user)):
    with get_session() as session:
        return bot_service.get_admin_overview(session)


@router.get("/bot/activity")
def compat_bot_activity(limit: int = 100, action: str | None = None, user=Depends(get_current_user)):
    with get_session() as session:
        items = bot_service.get_admin_activity(session=session, limit=max(1, min(limit, 500)), action=action)
    return {"items": items, "total": len(items)}


@router.get("/bot/settings")
def compat_bot_settings(user=Depends(get_current_user)):
    with get_session() as session:
        return {"items": bot_service.get_admin_settings(session)}


@router.put("/bot/settings")
async def compat_bot_settings_update(request: Request, user=Depends(get_current_user)):
    payload = await request.json()
    with get_session() as session:
        values = bot_service.update_admin_settings(
            session=session,
            values=payload,
            ip_address=request.client.host if request.client else None,
        )
    return {"items": values}


@router.api_route("/peers", methods=["GET", "POST"])
async def compat_peers_root(
    request: Request,
    user=Depends(get_current_user),
    session=Depends(_db_session),
):
    if request.method == "GET":
        return peers_list(
            status=request.query_params.get("status"),
            type=request.query_params.get("type"),
            group=request.query_params.get("group"),
            search=request.query_params.get("search"),
            _=user,
            session=session,
        )
    payload = await request.json()
    return peers_create(payload=payload, request=request, actor=user, session=session)


@router.post("/peers/batch")
async def compat_peers_batch(
    request: Request,
    user=Depends(get_current_user),
    session=Depends(_db_session),
):
    payload = await request.json()
    return peers_batch_create(payload=payload, request=request, actor=user, session=session)


@router.get("/peers/stats")
def compat_peers_stats(user=Depends(get_current_user), session=Depends(_db_session)):
    return peers_stats(_=user, session=session)


@router.get("/peers/{peer_id}")
def compat_peers_get(peer_id: int, user=Depends(get_current_user), session=Depends(_db_session)):
    return peers_get(peer_id=peer_id, _=user, session=session)


@router.put("/peers/{peer_id}")
async def compat_peers_update(
    peer_id: int,
    request: Request,
    user=Depends(get_current_user),
    session=Depends(_db_session),
):
    payload = await request.json()
    return peers_update(peer_id=peer_id, payload=payload, request=request, actor=user, session=session)


@router.delete("/peers/{peer_id}")
def compat_peers_delete(peer_id: int, request: Request, user=Depends(get_current_user), session=Depends(_db_session)):
    return peers_delete(peer_id=peer_id, request=request, actor=user, session=session)


@router.post("/peers/{peer_id}/disable")
def compat_peers_disable(peer_id: int, request: Request, user=Depends(get_current_user), session=Depends(_db_session)):
    return peers_disable(peer_id=peer_id, request=request, actor=user, session=session)


@router.post("/peers/{peer_id}/enable")
def compat_peers_enable(peer_id: int, request: Request, user=Depends(get_current_user), session=Depends(_db_session)):
    return peers_enable(peer_id=peer_id, request=request, actor=user, session=session)


@router.get("/peers/{peer_id}/config")
def compat_peers_config(peer_id: int, user=Depends(get_current_user), session=Depends(_db_session)):
    return peers_config(peer_id=peer_id, _=user, session=session)


@router.get("/peers/by-ip/{peer_ip}/config")
def compat_peers_config_by_ip(peer_ip: str, user=Depends(get_current_user), session=Depends(_db_session)):
    return peers_config_by_ip(peer_ip=peer_ip, _=user, session=session)


@router.post("/peers/by-ip/{peer_ip}/import")
def compat_peers_import(peer_ip: str, request: Request, user=Depends(get_current_user), session=Depends(_db_session)):
    return peers_import_by_ip(peer_ip=peer_ip, request=request, actor=user, session=session)


@router.get("/peers/{peer_id}/qr")
def compat_peers_qr(peer_id: int, user=Depends(get_current_user), session=Depends(_db_session)):
    return peers_qr(peer_id=peer_id, _=user, session=session)


@router.get("/monitoring/data")
def compat_monitoring_data(user=Depends(get_current_user)):
    return monitoring_data(_=user)


@router.get("/monitoring/peers")
def compat_monitoring_peers(user=Depends(get_current_user)):
    return monitoring_peers(_=user)


@router.get("/health")
def compat_health() -> dict[str, str]:
    return {"status": "ok"}
