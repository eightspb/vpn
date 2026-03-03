"""Native admin peers + monitoring endpoints for Stage 3."""

from __future__ import annotations

from datetime import date, datetime
import json
from pathlib import Path
import re
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from backend.api.routes.v1.admin import _db_session, require_permission
from backend.models import PeerDevice, User
from backend.services.audit_service import write_audit_event

router = APIRouter(prefix="/admin", tags=["admin-peers"])

PROJECT_ROOT = Path(__file__).resolve().parents[4]
CONFIGS_DIR = PROJECT_ROOT / "vpn-output"
MONITOR_DATA_PATH = PROJECT_ROOT / "scripts" / "monitor" / "vpn-output" / "data.json"

# 1x1 transparent PNG
EMPTY_QR_PNG_BASE64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO2WZp8AAAAASUVORK5CYII="


def _normalize_ip(value: str) -> str:
    return value.replace("_", ".").strip()


def _safe_filename(name: str) -> str:
    return re.sub(r"[^a-zA-Z0-9_-]", "_", name or "peer")


def _peer_payload(peer: PeerDevice) -> dict[str, Any]:
    downloaded_latest = False
    if peer.last_downloaded_config_version is not None:
        downloaded_latest = peer.last_downloaded_config_version >= (peer.config_version or 1)

    return {
        "id": peer.id,
        "name": peer.name,
        "ip": peer.ip,
        "type": peer.type,
        "mode": peer.mode,
        "public_key": peer.public_key,
        "private_key": peer.private_key,
        "preshared_key": None,
        "created_at": peer.created_at.isoformat() if peer.created_at else None,
        "updated_at": peer.updated_at.isoformat() if peer.updated_at else None,
        "status": peer.status,
        "expiry_date": peer.expiry_date.isoformat() if peer.expiry_date else None,
        "group_name": peer.group_name,
        "traffic_limit_mb": peer.traffic_limit_mb,
        "config_file": peer.config_file,
        "source": "db",
        "config_version": int(peer.config_version or 1),
        "config_download_count": int(peer.config_download_count or 0),
        "last_config_downloaded_at": peer.last_config_downloaded_at.isoformat() if peer.last_config_downloaded_at else None,
        "last_downloaded_config_version": peer.last_downloaded_config_version,
        "config_downloaded_latest": downloaded_latest,
        "config_download_required": not downloaded_latest,
        "config_runtime_active": False,
        "config_runtime_status": "inactive",
        "config_runtime_reason": "not_available_in_backend_mvp",
        "connection_status": "offline",
        "handshake_age_sec": None,
        "rx_bytes": None,
        "tx_bytes": None,
        "connection_threshold_sec": 55,
    }


def _scan_config_peers() -> list[dict[str, str]]:
    peers: list[dict[str, str]] = []
    if not CONFIGS_DIR.is_dir():
        return peers

    for config_path in CONFIGS_DIR.glob("*.conf"):
        try:
            text = config_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue

        ip = None
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.lower().startswith("address") and "=" in stripped:
                rhs = stripped.split("=", 1)[1].strip()
                value = rhs.split(",", 1)[0].strip()
                if "/" in value:
                    value = value.split("/", 1)[0].strip()
                ip = value
                break

        if not ip:
            continue

        peers.append(
            {
                "name": config_path.stem,
                "ip": ip,
                "config_file": str(config_path),
            }
        )

    return peers


def _allocate_ip(session: Session) -> str | None:
    used = {row[0] for row in session.execute(select(PeerDevice.ip)).all()}
    for i in range(3, 255):
        candidate = f"10.9.0.{i}"
        if candidate not in used:
            return candidate
    return None


def _build_config_content(peer: PeerDevice) -> str:
    # TODO(stage-4): build config from live server keys and settings.
    return (
        "[Interface]\n"
        f"# peer_id={peer.id}\n"
        f"# name={peer.name}\n"
        f"Address = {peer.ip}/32\n"
        "DNS = 1.1.1.1\n\n"
        "[Peer]\n"
        "# TODO: replace with server public key and endpoint\n"
        "PublicKey = TODO_SERVER_PUBLIC_KEY\n"
        "AllowedIPs = 0.0.0.0/0\n"
        "Endpoint = TODO_SERVER_ENDPOINT:51820\n"
        "PersistentKeepalive = 25\n"
    )


def _mark_downloaded(peer: PeerDevice) -> None:
    peer.config_download_count = int(peer.config_download_count or 0) + 1
    peer.last_downloaded_config_version = int(peer.config_version or 1)
    peer.last_config_downloaded_at = datetime.utcnow()


@router.get("/peers")
def peers_list(
    status: str | None = None,
    type: str | None = None,
    group: str | None = None,
    search: str | None = None,
    _: User = Depends(require_permission("peers:read")),
    session: Session = Depends(_db_session),
) -> list[dict[str, Any]]:
    stmt = select(PeerDevice)
    if status:
        stmt = stmt.where(PeerDevice.status == status)
    if type:
        stmt = stmt.where(PeerDevice.type == type)
    if group:
        stmt = stmt.where(PeerDevice.group_name == group)
    if search:
        pattern = f"%{search.strip()}%"
        stmt = stmt.where((PeerDevice.name.ilike(pattern)) | (PeerDevice.ip.ilike(pattern)))

    peers = session.scalars(stmt.order_by(PeerDevice.id.asc())).all()
    db_payload = [_peer_payload(peer) for peer in peers]

    db_ips = {item["ip"] for item in db_payload if item.get("ip")}
    if not status or status == "from_config":
        for config_peer in _scan_config_peers():
            if config_peer["ip"] in db_ips:
                continue
            if search and search.lower() not in config_peer["name"].lower() and search not in config_peer["ip"]:
                continue
            db_payload.append(
                {
                    "id": None,
                    "name": config_peer["name"],
                    "ip": config_peer["ip"],
                    "type": "phone",
                    "mode": "full",
                    "public_key": None,
                    "private_key": None,
                    "preshared_key": None,
                    "created_at": None,
                    "updated_at": None,
                    "status": "from_config",
                    "expiry_date": None,
                    "group_name": None,
                    "traffic_limit_mb": None,
                    "config_file": config_peer["config_file"],
                    "source": "config_file",
                    "config_version": 1,
                    "config_download_count": 0,
                    "last_config_downloaded_at": None,
                    "last_downloaded_config_version": None,
                    "config_downloaded_latest": False,
                    "config_download_required": True,
                    "config_runtime_active": False,
                    "config_runtime_status": "inactive",
                    "config_runtime_reason": "config_not_loaded_on_server",
                    "connection_status": "offline",
                    "handshake_age_sec": None,
                    "rx_bytes": None,
                    "tx_bytes": None,
                    "connection_threshold_sec": 55,
                }
            )

    return db_payload


@router.post("/peers")
def peers_create(
    payload: dict[str, Any],
    request: Request,
    actor: User = Depends(require_permission("peers:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    name = str(payload.get("name") or "").strip()
    if not name:
        raise HTTPException(status_code=400, detail="name is required")

    exists = session.scalar(select(PeerDevice).where(PeerDevice.name == name))
    if exists is not None:
        raise HTTPException(status_code=409, detail=f"Peer with name '{name}' already exists")

    ip = _allocate_ip(session)
    if not ip:
        raise HTTPException(status_code=507, detail="No available IPs in 10.9.0.3-254 range")

    group_name = payload.get("group_name")
    if group_name is not None:
        group_name = str(group_name).strip() or None

    expiry_date_value = payload.get("expiry_date")
    parsed_expiry: date | None = None
    if expiry_date_value:
        try:
            parsed_expiry = date.fromisoformat(str(expiry_date_value))
        except ValueError as exc:
            raise HTTPException(status_code=400, detail="expiry_date must be YYYY-MM-DD") from exc

    traffic_limit = payload.get("traffic_limit_mb")
    if traffic_limit in (None, ""):
        traffic_limit = None
    else:
        try:
            traffic_limit = int(traffic_limit)
        except (TypeError, ValueError) as exc:
            raise HTTPException(status_code=400, detail="traffic_limit_mb must be an integer") from exc

    config_path = CONFIGS_DIR / f"peer_{_safe_filename(name)}_{ip.replace('.', '_')}.conf"

    peer = PeerDevice(
        name=name,
        ip=ip,
        type=str(payload.get("type") or "phone").strip().lower() or "phone",
        mode="full",
        status="active",
        group_name=group_name,
        expiry_date=parsed_expiry,
        traffic_limit_mb=traffic_limit,
        config_file=str(config_path),
        created_at=datetime.utcnow(),
        updated_at=datetime.utcnow(),
        config_version=1,
        config_download_count=0,
    )
    session.add(peer)
    session.flush()

    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(_build_config_content(peer), encoding="utf-8")

    write_audit_event(
        session=session,
        action="peer_created",
        user_id=actor.id,
        target=f"peer:{peer.id}",
        details={"ip": peer.ip, "type": peer.type, "mode": "full"},
        ip_address=request.client.host if request.client else None,
    )
    return _peer_payload(peer)


@router.post("/peers/batch")
def peers_batch_create(
    payload: dict[str, Any],
    request: Request,
    actor: User = Depends(require_permission("peers:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    created: list[dict[str, Any]] = []
    errors: list[dict[str, Any]] = []

    csv_data = str(payload.get("csv") or "").strip()
    if csv_data:
        rows = [line.strip() for line in csv_data.splitlines() if line.strip()]
        for line in rows:
            cols = [c.strip() for c in line.split(",")]
            if not cols or cols[0].lower() == "name":
                continue
            name = cols[0]
            try:
                item = peers_create(
                    payload={"name": name, "type": cols[1] if len(cols) > 1 else "phone"},
                    request=request,
                    actor=actor,
                    session=session,
                )
                created.append(item)
            except HTTPException as exc:
                errors.append({"name": name, "error": str(exc.detail)})
    else:
        prefix = str(payload.get("prefix") or "peer").strip() or "peer"
        count = int(payload.get("count") or 0)
        ptype = str(payload.get("type") or "phone").strip() or "phone"
        if count <= 0:
            raise HTTPException(status_code=400, detail="count must be > 0")
        for i in range(1, count + 1):
            name = f"{prefix}-{i:03d}"
            try:
                item = peers_create(payload={"name": name, "type": ptype}, request=request, actor=actor, session=session)
                created.append(item)
            except HTTPException as exc:
                errors.append({"name": name, "error": str(exc.detail)})

    write_audit_event(
        session=session,
        action="peers_batch_created",
        user_id=actor.id,
        target="peers",
        details={"created": len(created), "failed": len(errors)},
        ip_address=request.client.host if request.client else None,
    )
    return {"created": created, "errors": errors, "total": len(created), "failed": len(errors)}


@router.get("/peers/{peer_id}")
def peers_get(
    peer_id: int,
    _: User = Depends(require_permission("peers:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    peer = session.get(PeerDevice, peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="Peer not found")
    return _peer_payload(peer)


@router.put("/peers/{peer_id}")
def peers_update(
    peer_id: int,
    payload: dict[str, Any],
    request: Request,
    actor: User = Depends(require_permission("peers:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    peer = session.get(PeerDevice, peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="Peer not found")

    config_sensitive = {"name", "type", "config_file", "private_key"}
    changed_sensitive = False

    if "name" in payload:
        name = str(payload.get("name") or "").strip()
        if not name:
            raise HTTPException(status_code=400, detail="name cannot be empty")
        dupe = session.scalar(select(PeerDevice).where(PeerDevice.name == name, PeerDevice.id != peer_id))
        if dupe is not None:
            raise HTTPException(status_code=409, detail=f"Peer with name '{name}' already exists")
        changed_sensitive = changed_sensitive or (peer.name != name)
        peer.name = name

    if "type" in payload:
        value = str(payload.get("type") or "").strip().lower()
        if not value:
            raise HTTPException(status_code=400, detail="type cannot be empty")
        changed_sensitive = changed_sensitive or (peer.type != value)
        peer.type = value

    if "group_name" in payload:
        value = payload.get("group_name")
        peer.group_name = (str(value).strip() or None) if value is not None else None

    if "status" in payload:
        value = str(payload.get("status") or "").strip().lower()
        if value not in {"active", "disabled", "revoked"}:
            raise HTTPException(status_code=400, detail="status must be one of: active, disabled, revoked")
        peer.status = value

    if "expiry_date" in payload:
        value = payload.get("expiry_date")
        if value in (None, ""):
            peer.expiry_date = None
        else:
            try:
                peer.expiry_date = date.fromisoformat(str(value))
            except ValueError as exc:
                raise HTTPException(status_code=400, detail="expiry_date must be YYYY-MM-DD") from exc

    if "traffic_limit_mb" in payload:
        value = payload.get("traffic_limit_mb")
        if value in (None, ""):
            peer.traffic_limit_mb = None
        else:
            try:
                parsed = int(value)
            except (TypeError, ValueError) as exc:
                raise HTTPException(status_code=400, detail="traffic_limit_mb must be an integer") from exc
            if parsed < 0:
                raise HTTPException(status_code=400, detail="traffic_limit_mb must be >= 0")
            peer.traffic_limit_mb = parsed

    if "config_file" in payload:
        value = str(payload.get("config_file") or "").strip() or None
        changed_sensitive = changed_sensitive or (peer.config_file != value)
        peer.config_file = value

    if changed_sensitive:
        peer.config_version = int(peer.config_version or 1) + 1

    peer.updated_at = datetime.utcnow()

    write_audit_event(
        session=session,
        action="peer_updated",
        user_id=actor.id,
        target=f"peer:{peer.id}",
        details={k: payload.get(k) for k in payload.keys()},
        ip_address=request.client.host if request.client else None,
    )
    return _peer_payload(peer)


@router.post("/peers/by-ip/{peer_ip}/import")
def peers_import_by_ip(
    peer_ip: str,
    request: Request,
    actor: User = Depends(require_permission("peers:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    ip = _normalize_ip(peer_ip)
    existing = session.scalar(select(PeerDevice).where(PeerDevice.ip == ip))
    if existing is not None:
        return _peer_payload(existing)

    config_peer = next((item for item in _scan_config_peers() if item["ip"] == ip), None)
    if config_peer is None:
        raise HTTPException(status_code=404, detail="Peer config not found")

    base_name = (config_peer.get("name") or f"peer-{ip.replace('.', '-')}").strip()
    name = base_name
    suffix = 1
    while session.scalar(select(PeerDevice).where(PeerDevice.name == name)) is not None:
        suffix += 1
        name = f"{base_name}-{suffix}"

    peer = PeerDevice(
        name=name,
        ip=ip,
        type="phone",
        mode="full",
        status="active",
        config_file=config_peer.get("config_file"),
        created_at=datetime.utcnow(),
        updated_at=datetime.utcnow(),
        config_version=1,
        config_download_count=0,
    )
    session.add(peer)
    session.flush()

    write_audit_event(
        session=session,
        action="peer_imported_from_config",
        user_id=actor.id,
        target=f"peer:{peer.id}",
        details={"ip": ip, "config_file": config_peer.get("config_file")},
        ip_address=request.client.host if request.client else None,
    )
    return _peer_payload(peer)


@router.delete("/peers/{peer_id}")
def peers_delete(
    peer_id: int,
    request: Request,
    actor: User = Depends(require_permission("peers:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    peer = session.get(PeerDevice, peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="Peer not found")

    config_path = Path(peer.config_file) if peer.config_file else None
    if config_path and config_path.exists():
        config_path.unlink(missing_ok=True)

    name = peer.name
    ip = peer.ip
    session.delete(peer)
    write_audit_event(
        session=session,
        action="peer_deleted",
        user_id=actor.id,
        target=f"peer:{peer_id}",
        details={"ip": ip},
        ip_address=request.client.host if request.client else None,
    )
    return {"ok": True, "deleted": name}


@router.post("/peers/{peer_id}/disable")
def peers_disable(
    peer_id: int,
    request: Request,
    actor: User = Depends(require_permission("peers:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    peer = session.get(PeerDevice, peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="Peer not found")
    peer.status = "disabled"
    peer.updated_at = datetime.utcnow()
    write_audit_event(
        session=session,
        action="peer_disabled",
        user_id=actor.id,
        target=f"peer:{peer.id}",
        details=None,
        ip_address=request.client.host if request.client else None,
    )
    return {"ok": True, "status": "disabled"}


@router.post("/peers/{peer_id}/enable")
def peers_enable(
    peer_id: int,
    request: Request,
    actor: User = Depends(require_permission("peers:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    peer = session.get(PeerDevice, peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="Peer not found")
    peer.status = "active"
    peer.updated_at = datetime.utcnow()
    write_audit_event(
        session=session,
        action="peer_enabled",
        user_id=actor.id,
        target=f"peer:{peer.id}",
        details=None,
        ip_address=request.client.host if request.client else None,
    )
    return {"ok": True, "status": "active"}


@router.get("/peers/{peer_id}/config")
def peers_config(
    peer_id: int,
    _: User = Depends(require_permission("peers:read")),
    session: Session = Depends(_db_session),
) -> Response:
    peer = session.get(PeerDevice, peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="Peer not found")

    content = None
    config_path = Path(peer.config_file) if peer.config_file else None
    if config_path and config_path.exists():
        content = config_path.read_text(encoding="utf-8", errors="replace")
    if not content:
        content = _build_config_content(peer)

    _mark_downloaded(peer)
    filename = _safe_filename(peer.name)
    return Response(
        content=content,
        media_type="text/plain",
        headers={"Content-Disposition": f'attachment; filename="{filename}.conf"'},
    )


@router.get("/peers/by-ip/{peer_ip}/config")
def peers_config_by_ip(
    peer_ip: str,
    _: User = Depends(require_permission("peers:read")),
    session: Session = Depends(_db_session),
) -> Response:
    ip = _normalize_ip(peer_ip)

    peer = session.scalar(select(PeerDevice).where(PeerDevice.ip == ip))
    if peer is not None:
        return peers_config(peer_id=peer.id, _=_, session=session)

    config_peer = next((item for item in _scan_config_peers() if item["ip"] == ip), None)
    if config_peer is None:
        raise HTTPException(status_code=404, detail="Config not found")

    path = Path(config_peer["config_file"])
    if not path.exists():
        raise HTTPException(status_code=404, detail="Config not found")

    content = path.read_text(encoding="utf-8", errors="replace")
    filename = _safe_filename(config_peer["name"])
    return Response(
        content=content,
        media_type="text/plain",
        headers={"Content-Disposition": f'attachment; filename="{filename}.conf"'},
    )


@router.get("/peers/{peer_id}/qr")
def peers_qr(
    peer_id: int,
    _: User = Depends(require_permission("peers:read")),
    session: Session = Depends(_db_session),
) -> dict[str, str]:
    peer = session.get(PeerDevice, peer_id)
    if peer is None:
        raise HTTPException(status_code=404, detail="Peer not found")
    return {"qr_png_base64": EMPTY_QR_PNG_BASE64}


@router.get("/peers/stats")
def peers_stats(
    _: User = Depends(require_permission("peers:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    total_range = 252
    used = session.scalar(select(func.count(PeerDevice.id))) or 0

    by_status_rows = session.execute(
        select(PeerDevice.status, func.count(PeerDevice.id)).group_by(PeerDevice.status)
    ).all()
    by_type_rows = session.execute(
        select(PeerDevice.type, func.count(PeerDevice.id)).group_by(PeerDevice.type)
    ).all()

    return {
        "total_range": total_range,
        "used": int(used),
        "available": max(total_range - int(used), 0),
        "by_status": {str(status): int(cnt) for status, cnt in by_status_rows},
        "by_type": {str(kind): int(cnt) for kind, cnt in by_type_rows},
    }


@router.get("/monitoring/data")
def monitoring_data(_: User = Depends(require_permission("monitoring:read"))) -> dict[str, Any]:
    if not MONITOR_DATA_PATH.is_file():
        return {
            "error": "Monitoring data not available",
            "path": str(MONITOR_DATA_PATH),
            "_monitor_running": False,
        }

    try:
        payload = json.loads(MONITOR_DATA_PATH.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        raise HTTPException(status_code=500, detail="Failed to read monitoring data")

    payload["_monitor_running"] = True
    return payload


@router.get("/monitoring/peers")
def monitoring_peers(_: User = Depends(require_permission("monitoring:read"))) -> list[dict[str, Any]]:
    # Stage 3: monitoring peers endpoint is kept native in new backend.
    # TODO(stage-4): add live SSH wg-dump integration with idempotent parsing.
    return []
