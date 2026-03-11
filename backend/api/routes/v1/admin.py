"""Admin API v1: auth, RBAC, users/plans/offers/subscriptions/transactions/settings."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from decimal import Decimal
import secrets
from typing import Any, Callable, Optional

from fastapi import APIRouter, Depends, HTTPException, Request, Response, status
from pydantic import BaseModel, Field
from sqlalchemy import func, select
from sqlalchemy.orm import Session

from backend.core.config import get_settings
from backend.db.session import get_session
from backend.models import (
    AuditLog,
    BroadcastCampaign,
    Plan,
    PlanKind,
    PlanOffer,
    Promocode,
    PromocodeKind,
    Setting,
    Subscription,
    Transaction,
    User,
    WorkerDeadLetter,
    WorkerJobRun,
)
from backend.models.enums import RoleEnum, SubscriptionStatus, TransactionStatus
from backend.services.audit_service import write_audit_event
from backend.services.bot_service import TelegramGateway, build_bot_service
from backend.services.broadcast_service import BroadcastService
from backend.services.notifications_service import NotificationsService

router = APIRouter(prefix="/admin", tags=["admin"])
bot_service = build_bot_service()
_notification_service = NotificationsService(
    TelegramGateway(
        token=get_settings().TELEGRAM_BOT_TOKEN,
        outbound_enabled=get_settings().BOT_OUTBOUND_ENABLED,
    )
)
broadcast_service = BroadcastService(_notification_service)

# In-memory rate limiter for login: IP -> (attempt_count, window_start_timestamp)
_login_rate_limiter: dict[str, tuple[int, float]] = {}
_RATE_LIMIT_WINDOW = 60  # seconds
_RATE_LIMIT_MAX_ATTEMPTS = 5  # max attempts per window

try:
    import bcrypt  # type: ignore
except ImportError as e:  # pragma: no cover
    raise RuntimeError("bcrypt is required for password hashing") from e


@dataclass
class SessionInfo:
    user_id: int
    expires_at: datetime


_SESSIONS: dict[str, SessionInfo] = {}

SESSION_COOKIE_NAME = "admin_sid"
SESSION_TTL_HOURS = 24


PERMISSIONS: dict[str, set[str]] = {
    "owner": {"*"},
    "admin": {
        "users:read",
        "users:write",
        "plans:read",
        "plans:write",
        "offers:read",
        "offers:write",
        "subscriptions:read",
        "subscriptions:write",
        "transactions:read",
        "settings:read",
        "settings:write",
        "promocodes:read",
        "promocodes:write",
        "audit:read",
        "peers:read",
        "peers:write",
        "monitoring:read",
        "broadcasts:read",
        "broadcasts:write",
        "workers:read",
    },
    "operator": {
        "users:read",
        "plans:read",
        "offers:read",
        "subscriptions:read",
        "subscriptions:write",
        "transactions:read",
        "settings:read",
        "promocodes:read",
        "audit:read",
        "peers:read",
        "peers:write",
        "monitoring:read",
        "broadcasts:read",
        "broadcasts:write",
        "workers:read",
    },
    "readonly": {
        "users:read",
        "plans:read",
        "offers:read",
        "subscriptions:read",
        "transactions:read",
        "settings:read",
        "promocodes:read",
        "audit:read",
        "peers:read",
        "monitoring:read",
        "broadcasts:read",
        "workers:read",
    },
    "support": {
        "users:read",
        "subscriptions:read",
        "transactions:read",
        "audit:read",
        "peers:read",
        "monitoring:read",
    },
    "user": set(),
}


def _db_session() -> Session:
    with get_session() as session:
        yield session


def _verify_password(plain_password: str, stored_hash: str) -> bool:
    # All stored hashes must be bcrypt hashes (no plaintext fallback)
    if not stored_hash:
        return False
    try:
        return bcrypt.checkpw(plain_password.encode("utf-8"), stored_hash.encode("utf-8"))
    except ValueError:
        return False


def _hash_password(plain_password: str) -> str:
    return bcrypt.hashpw(plain_password.encode("utf-8"), bcrypt.gensalt()).decode("utf-8")


def _user_payload(user: User) -> dict[str, Any]:
    return {
        "id": user.id,
        "username": user.username,
        "role": user.role.value,
        "is_blocked": bool(user.is_blocked),
        "created_at": user.created_at.isoformat() if user.created_at else None,
        "last_login": user.last_login.isoformat() if user.last_login else None,
    }


def _prune_sessions() -> None:
    now = datetime.utcnow()
    expired = [sid for sid, info in _SESSIONS.items() if info.expires_at <= now]
    for sid in expired:
        _SESSIONS.pop(sid, None)


def _has_permission(role: str, permission: str) -> bool:
    role_perms = PERMISSIONS.get(role, set())
    return "*" in role_perms or permission in role_perms


def get_current_user(
    request: Request,
    session: Session = Depends(_db_session),
) -> User:
    _prune_sessions()
    sid = request.cookies.get(SESSION_COOKIE_NAME, "")
    info = _SESSIONS.get(sid)
    if not info:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="unauthorized")

    user = session.get(User, info.user_id)
    if user is None:
        _SESSIONS.pop(sid, None)
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="unauthorized")
    if user.is_blocked:
        _SESSIONS.pop(sid, None)
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="user blocked")
    return user


def require_permission(permission: str) -> Callable[[User], User]:
    def _checker(user: User = Depends(get_current_user)) -> User:
        role = user.role.value
        if not _has_permission(role, permission):
            raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="forbidden")
        return user

    return _checker


class LoginRequest(BaseModel):
    username: str
    password: str


class ChangePasswordRequest(BaseModel):
    old_password: str
    new_password: str = Field(min_length=8, max_length=256)


class UserUpdateRequest(BaseModel):
    role: Optional[RoleEnum] = None
    is_blocked: Optional[bool] = None


class PlanCreateRequest(BaseModel):
    name: str
    kind: PlanKind
    description: Optional[str] = None
    traffic_limit_mb: Optional[int] = None
    device_limit: Optional[int] = None


class PlanUpdateRequest(BaseModel):
    name: Optional[str] = None
    kind: Optional[PlanKind] = None
    description: Optional[str] = None
    traffic_limit_mb: Optional[int] = None
    device_limit: Optional[int] = None


class OfferCreateRequest(BaseModel):
    plan_id: int
    duration_days: int = Field(ge=1)
    price: Decimal
    currency: str = Field(min_length=3, max_length=3)


class OfferUpdateRequest(BaseModel):
    plan_id: Optional[int] = None
    duration_days: Optional[int] = Field(default=None, ge=1)
    price: Optional[Decimal] = None
    currency: Optional[str] = Field(default=None, min_length=3, max_length=3)


class SubscriptionUpdateRequest(BaseModel):
    status: Optional[SubscriptionStatus] = None
    started_at: Optional[datetime] = None
    expires_at: Optional[datetime] = None


class SettingsUpdateRequest(BaseModel):
    items: dict[str, str]


class PromocodeCreateRequest(BaseModel):
    code: str = Field(min_length=3, max_length=64)
    kind: PromocodeKind
    value: Decimal = Field(gt=0)
    usage_limit: int | None = Field(default=None, ge=1)
    expires_at: datetime | None = None
    is_active: bool = True


class PromocodeUpdateRequest(BaseModel):
    kind: PromocodeKind | None = None
    value: Decimal | None = Field(default=None, gt=0)
    usage_limit: int | None = Field(default=None, ge=1)
    expires_at: datetime | None = None
    is_active: bool | None = None


class BroadcastCreateRequest(BaseModel):
    segment: str = Field(min_length=3, max_length=16)
    message: str = Field(min_length=1, max_length=4000)


@router.post("/auth/login")
def login(payload: LoginRequest, request: Request, response: Response, session: Session = Depends(_db_session)) -> dict[str, Any]:
    # Rate limiting by client IP
    client_ip = request.client.host if request.client else "unknown"
    now = datetime.utcnow().timestamp()

    if client_ip in _login_rate_limiter:
        attempt_count, window_start = _login_rate_limiter[client_ip]
        if now - window_start < _RATE_LIMIT_WINDOW:
            if attempt_count >= _RATE_LIMIT_MAX_ATTEMPTS:
                raise HTTPException(status_code=429, detail="Too many login attempts")
            _login_rate_limiter[client_ip] = (attempt_count + 1, window_start)
        else:
            _login_rate_limiter[client_ip] = (1, now)
    else:
        _login_rate_limiter[client_ip] = (1, now)

    user = session.scalar(select(User).where(User.username == payload.username))
    if user is None or not _verify_password(payload.password, user.password_hash):
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="invalid credentials")
    if user.is_blocked:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="user blocked")

    sid = secrets.token_urlsafe(32)
    _SESSIONS[sid] = SessionInfo(
        user_id=user.id,
        expires_at=datetime.utcnow() + timedelta(hours=SESSION_TTL_HOURS),
    )

    user.last_login = datetime.utcnow()
    write_audit_event(
        session=session,
        action="admin_login",
        user_id=user.id,
        target=f"user:{user.id}",
        details={"username": user.username},
        ip_address=request.client.host if request.client else None,
    )

    settings = get_settings()
    response.set_cookie(
        key=SESSION_COOKIE_NAME,
        value=sid,
        httponly=True,
        secure=settings.APP_ENV != "development",
        samesite="strict",
        max_age=SESSION_TTL_HOURS * 3600,
        path="/",
    )

    return {"ok": True, "user": _user_payload(user)}


@router.post("/auth/logout")
def logout(request: Request, response: Response, user: User = Depends(get_current_user), session: Session = Depends(_db_session)) -> dict[str, bool]:
    sid = request.cookies.get(SESSION_COOKIE_NAME, "")
    if sid:
        _SESSIONS.pop(sid, None)

    write_audit_event(
        session=session,
        action="admin_logout",
        user_id=user.id,
        target=f"user:{user.id}",
        details=None,
        ip_address=request.client.host if request.client else None,
    )

    response.delete_cookie(SESSION_COOKIE_NAME, path="/")
    return {"ok": True}


@router.get("/auth/me")
def me(user: User = Depends(get_current_user)) -> dict[str, Any]:
    return _user_payload(user)


@router.post("/auth/change-password")
def change_password(
    payload: ChangePasswordRequest,
    request: Request,
    user: User = Depends(get_current_user),
    session: Session = Depends(_db_session),
) -> dict[str, bool]:
    if not _verify_password(payload.old_password, user.password_hash):
        raise HTTPException(status_code=400, detail="old_password is incorrect")
    user.password_hash = _hash_password(payload.new_password)
    write_audit_event(
        session=session,
        action="admin_password_changed",
        user_id=user.id,
        target=f"user:{user.id}",
        details=None,
        ip_address=request.client.host if request.client else None,
    )
    return {"ok": True}


@router.get("/users")
def users_list(
    page: int = 1,
    per_page: int = 50,
    query: str | None = None,
    _: User = Depends(require_permission("users:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    page = max(page, 1)
    per_page = min(max(per_page, 1), 200)

    stmt = select(User)
    count_stmt = select(func.count(User.id))
    if query:
        pattern = f"%{query.strip()}%"
        stmt = stmt.where(User.username.ilike(pattern))
        count_stmt = count_stmt.where(User.username.ilike(pattern))

    total = session.scalar(count_stmt) or 0
    items = session.scalars(
        stmt.order_by(User.id.desc()).offset((page - 1) * per_page).limit(per_page)
    ).all()
    pages = max((total + per_page - 1) // per_page, 1)

    return {
        "items": [_user_payload(item) for item in items],
        "total": int(total),
        "page": page,
        "pages": pages,
    }


@router.get("/users/{user_id}")
def users_get(
    user_id: int,
    _: User = Depends(require_permission("users:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    user = session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="user not found")
    return _user_payload(user)


@router.put("/users/{user_id}")
def users_update(
    user_id: int,
    payload: UserUpdateRequest,
    request: Request,
    actor: User = Depends(require_permission("users:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    user = session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="user not found")

    if payload.role is not None:
        user.role = payload.role
    if payload.is_blocked is not None:
        user.is_blocked = payload.is_blocked

    write_audit_event(
        session=session,
        action="admin_user_updated",
        user_id=actor.id,
        target=f"user:{user.id}",
        details={"role": user.role.value, "is_blocked": user.is_blocked},
        ip_address=request.client.host if request.client else None,
    )
    return _user_payload(user)


@router.post("/users/{user_id}/block")
def users_block(
    user_id: int,
    request: Request,
    actor: User = Depends(require_permission("users:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    user = session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="user not found")
    user.is_blocked = True
    write_audit_event(
        session=session,
        action="admin_user_blocked",
        user_id=actor.id,
        target=f"user:{user.id}",
        details={"is_blocked": True},
        ip_address=request.client.host if request.client else None,
    )
    return _user_payload(user)


@router.post("/users/{user_id}/unblock")
def users_unblock(
    user_id: int,
    request: Request,
    actor: User = Depends(require_permission("users:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    user = session.get(User, user_id)
    if user is None:
        raise HTTPException(status_code=404, detail="user not found")
    user.is_blocked = False
    write_audit_event(
        session=session,
        action="admin_user_unblocked",
        user_id=actor.id,
        target=f"user:{user.id}",
        details={"is_blocked": False},
        ip_address=request.client.host if request.client else None,
    )
    return _user_payload(user)


def _plan_payload(plan: Plan) -> dict[str, Any]:
    return {
        "id": plan.id,
        "name": plan.name,
        "kind": plan.kind.value,
        "description": plan.description,
        "traffic_limit_mb": plan.traffic_limit_mb,
        "device_limit": plan.device_limit,
        "created_at": plan.created_at.isoformat() if plan.created_at else None,
    }


@router.get("/plans")
def plans_list(
    _: User = Depends(require_permission("plans:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    plans = session.scalars(select(Plan).order_by(Plan.id.asc())).all()
    return {"items": [_plan_payload(p) for p in plans], "total": len(plans)}


@router.post("/plans")
def plans_create(
    payload: PlanCreateRequest,
    request: Request,
    actor: User = Depends(require_permission("plans:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    plan = Plan(
        name=payload.name.strip(),
        kind=payload.kind,
        description=payload.description,
        traffic_limit_mb=payload.traffic_limit_mb,
        device_limit=payload.device_limit,
    )
    session.add(plan)
    session.flush()
    write_audit_event(
        session=session,
        action="admin_plan_created",
        user_id=actor.id,
        target=f"plan:{plan.id}",
        details=_plan_payload(plan),
        ip_address=request.client.host if request.client else None,
    )
    return _plan_payload(plan)


@router.get("/plans/{plan_id}")
def plans_get(
    plan_id: int,
    _: User = Depends(require_permission("plans:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    plan = session.get(Plan, plan_id)
    if plan is None:
        raise HTTPException(status_code=404, detail="plan not found")
    return _plan_payload(plan)


@router.put("/plans/{plan_id}")
def plans_update(
    plan_id: int,
    payload: PlanUpdateRequest,
    request: Request,
    actor: User = Depends(require_permission("plans:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    plan = session.get(Plan, plan_id)
    if plan is None:
        raise HTTPException(status_code=404, detail="plan not found")

    data = payload.model_dump(exclude_unset=True)
    for key, value in data.items():
        setattr(plan, key, value)

    write_audit_event(
        session=session,
        action="admin_plan_updated",
        user_id=actor.id,
        target=f"plan:{plan.id}",
        details=data,
        ip_address=request.client.host if request.client else None,
    )
    return _plan_payload(plan)


@router.delete("/plans/{plan_id}")
def plans_delete(
    plan_id: int,
    request: Request,
    actor: User = Depends(require_permission("plans:write")),
    session: Session = Depends(_db_session),
) -> dict[str, bool]:
    plan = session.get(Plan, plan_id)
    if plan is None:
        raise HTTPException(status_code=404, detail="plan not found")
    session.delete(plan)
    write_audit_event(
        session=session,
        action="admin_plan_deleted",
        user_id=actor.id,
        target=f"plan:{plan_id}",
        details=None,
        ip_address=request.client.host if request.client else None,
    )
    return {"ok": True}


def _offer_payload(offer: PlanOffer) -> dict[str, Any]:
    return {
        "id": offer.id,
        "plan_id": offer.plan_id,
        "duration_days": offer.duration_days,
        "price": str(offer.price),
        "currency": offer.currency,
        "created_at": offer.created_at.isoformat() if offer.created_at else None,
    }


@router.get("/offers")
def offers_list(
    plan_id: int | None = None,
    _: User = Depends(require_permission("offers:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    stmt = select(PlanOffer)
    if plan_id is not None:
        stmt = stmt.where(PlanOffer.plan_id == plan_id)
    items = session.scalars(stmt.order_by(PlanOffer.id.asc())).all()
    return {"items": [_offer_payload(item) for item in items], "total": len(items)}


@router.post("/offers")
def offers_create(
    payload: OfferCreateRequest,
    request: Request,
    actor: User = Depends(require_permission("offers:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    if session.get(Plan, payload.plan_id) is None:
        raise HTTPException(status_code=404, detail="plan not found")
    offer = PlanOffer(
        plan_id=payload.plan_id,
        duration_days=payload.duration_days,
        price=payload.price,
        currency=payload.currency.upper(),
    )
    session.add(offer)
    session.flush()
    write_audit_event(
        session=session,
        action="admin_offer_created",
        user_id=actor.id,
        target=f"offer:{offer.id}",
        details=_offer_payload(offer),
        ip_address=request.client.host if request.client else None,
    )
    return _offer_payload(offer)


@router.get("/offers/{offer_id}")
def offers_get(
    offer_id: int,
    _: User = Depends(require_permission("offers:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    offer = session.get(PlanOffer, offer_id)
    if offer is None:
        raise HTTPException(status_code=404, detail="offer not found")
    return _offer_payload(offer)


@router.put("/offers/{offer_id}")
def offers_update(
    offer_id: int,
    payload: OfferUpdateRequest,
    request: Request,
    actor: User = Depends(require_permission("offers:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    offer = session.get(PlanOffer, offer_id)
    if offer is None:
        raise HTTPException(status_code=404, detail="offer not found")

    data = payload.model_dump(exclude_unset=True)
    if "plan_id" in data and session.get(Plan, data["plan_id"]) is None:
        raise HTTPException(status_code=404, detail="plan not found")
    if "currency" in data and data["currency"] is not None:
        data["currency"] = str(data["currency"]).upper()

    for key, value in data.items():
        setattr(offer, key, value)

    write_audit_event(
        session=session,
        action="admin_offer_updated",
        user_id=actor.id,
        target=f"offer:{offer.id}",
        details=data,
        ip_address=request.client.host if request.client else None,
    )
    return _offer_payload(offer)


@router.delete("/offers/{offer_id}")
def offers_delete(
    offer_id: int,
    request: Request,
    actor: User = Depends(require_permission("offers:write")),
    session: Session = Depends(_db_session),
) -> dict[str, bool]:
    offer = session.get(PlanOffer, offer_id)
    if offer is None:
        raise HTTPException(status_code=404, detail="offer not found")
    session.delete(offer)
    write_audit_event(
        session=session,
        action="admin_offer_deleted",
        user_id=actor.id,
        target=f"offer:{offer_id}",
        details=None,
        ip_address=request.client.host if request.client else None,
    )
    return {"ok": True}


def _subscription_payload(item: Subscription) -> dict[str, Any]:
    return {
        "id": item.id,
        "user_id": item.user_id,
        "plan_offer_id": item.plan_offer_id,
        "status": item.status.value,
        "started_at": item.started_at.isoformat() if item.started_at else None,
        "expires_at": item.expires_at.isoformat() if item.expires_at else None,
        "created_at": item.created_at.isoformat() if item.created_at else None,
    }


@router.get("/subscriptions")
def subscriptions_list(
    user_id: int | None = None,
    status_value: str | None = None,
    _: User = Depends(require_permission("subscriptions:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    stmt = select(Subscription)
    if user_id is not None:
        stmt = stmt.where(Subscription.user_id == user_id)
    if status_value:
        try:
            status_enum = SubscriptionStatus(status_value)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=f"invalid status: {status_value}") from exc
        stmt = stmt.where(Subscription.status == status_enum)
    items = session.scalars(stmt.order_by(Subscription.id.desc())).all()
    return {"items": [_subscription_payload(i) for i in items], "total": len(items)}


@router.get("/subscriptions/{subscription_id}")
def subscriptions_get(
    subscription_id: int,
    _: User = Depends(require_permission("subscriptions:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    item = session.get(Subscription, subscription_id)
    if item is None:
        raise HTTPException(status_code=404, detail="subscription not found")
    return _subscription_payload(item)


@router.put("/subscriptions/{subscription_id}")
def subscriptions_update(
    subscription_id: int,
    payload: SubscriptionUpdateRequest,
    request: Request,
    actor: User = Depends(require_permission("subscriptions:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    item = session.get(Subscription, subscription_id)
    if item is None:
        raise HTTPException(status_code=404, detail="subscription not found")

    data = payload.model_dump(exclude_unset=True)
    for key, value in data.items():
        setattr(item, key, value)

    write_audit_event(
        session=session,
        action="admin_subscription_updated",
        user_id=actor.id,
        target=f"subscription:{item.id}",
        details={k: (v.value if hasattr(v, "value") else str(v)) for k, v in data.items()},
        ip_address=request.client.host if request.client else None,
    )
    return _subscription_payload(item)


def _transaction_payload(item: Transaction) -> dict[str, Any]:
    return {
        "id": item.id,
        "subscription_id": item.subscription_id,
        "amount": str(item.amount),
        "currency": item.currency,
        "provider": item.provider,
        "external_id": item.external_id,
        "status": item.status.value,
        "original_amount": str(item.original_amount) if item.original_amount is not None else None,
        "discount_amount": str(item.discount_amount) if item.discount_amount is not None else None,
        "is_trial": bool(item.is_trial),
        "promocode_id": item.promocode_id,
        "created_at": item.created_at.isoformat() if item.created_at else None,
    }


@router.get("/transactions")
def transactions_list(
    status_value: str | None = None,
    provider: str | None = None,
    from_ts: datetime | None = None,
    to_ts: datetime | None = None,
    _: User = Depends(require_permission("transactions:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    stmt = select(Transaction)
    if status_value:
        try:
            status_enum = TransactionStatus(status_value)
        except ValueError as exc:
            raise HTTPException(status_code=400, detail=f"invalid status: {status_value}") from exc
        stmt = stmt.where(Transaction.status == status_enum)
    if provider:
        stmt = stmt.where(Transaction.provider == provider)
    if from_ts is not None:
        stmt = stmt.where(Transaction.created_at >= from_ts)
    if to_ts is not None:
        stmt = stmt.where(Transaction.created_at <= to_ts)

    items = session.scalars(stmt.order_by(Transaction.id.desc())).all()
    return {"items": [_transaction_payload(i) for i in items], "total": len(items)}


@router.get("/transactions/{transaction_id}")
def transactions_get(
    transaction_id: int,
    _: User = Depends(require_permission("transactions:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    item = session.get(Transaction, transaction_id)
    if item is None:
        raise HTTPException(status_code=404, detail="transaction not found")
    return _transaction_payload(item)


def _promocode_payload(item: Promocode) -> dict[str, Any]:
    return {
        "id": item.id,
        "code": item.code,
        "kind": item.kind.value,
        "value": str(item.value),
        "is_active": bool(item.is_active),
        "usage_limit": item.usage_limit,
        "used_count": item.used_count,
        "expires_at": item.expires_at.isoformat() if item.expires_at else None,
        "created_at": item.created_at.isoformat() if item.created_at else None,
    }


@router.get("/promocodes")
def promocodes_list(
    active_only: bool = False,
    _: User = Depends(require_permission("promocodes:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    stmt = select(Promocode)
    if active_only:
        stmt = stmt.where(Promocode.is_active.is_(True))
    items = session.scalars(stmt.order_by(Promocode.id.desc())).all()
    return {"items": [_promocode_payload(item) for item in items], "total": len(items)}


@router.post("/promocodes")
def promocodes_create(
    payload: PromocodeCreateRequest,
    request: Request,
    actor: User = Depends(require_permission("promocodes:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    code = payload.code.strip().upper()
    exists = session.scalar(select(Promocode.id).where(Promocode.code == code))
    if exists is not None:
        raise HTTPException(status_code=409, detail="promocode already exists")
    item = Promocode(
        code=code,
        kind=payload.kind,
        value=payload.value,
        usage_limit=payload.usage_limit,
        expires_at=payload.expires_at,
        is_active=payload.is_active,
    )
    session.add(item)
    session.flush()
    write_audit_event(
        session=session,
        action="admin_promocode_created",
        user_id=actor.id,
        target=f"promocode:{item.id}",
        details=_promocode_payload(item),
        ip_address=request.client.host if request.client else None,
    )
    return _promocode_payload(item)


@router.put("/promocodes/{promocode_id}")
def promocodes_update(
    promocode_id: int,
    payload: PromocodeUpdateRequest,
    request: Request,
    actor: User = Depends(require_permission("promocodes:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    item = session.get(Promocode, promocode_id)
    if item is None:
        raise HTTPException(status_code=404, detail="promocode not found")
    data = payload.model_dump(exclude_unset=True)
    for key, value in data.items():
        setattr(item, key, value)
    write_audit_event(
        session=session,
        action="admin_promocode_updated",
        user_id=actor.id,
        target=f"promocode:{item.id}",
        details=data,
        ip_address=request.client.host if request.client else None,
    )
    return _promocode_payload(item)


@router.get("/settings")
def settings_get(
    _: User = Depends(require_permission("settings:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    items = session.scalars(select(Setting).order_by(Setting.key.asc())).all()
    return {"items": {item.key: item.value or "" for item in items}}


@router.put("/settings")
def settings_update(
    payload: SettingsUpdateRequest,
    request: Request,
    actor: User = Depends(require_permission("settings:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    updated: dict[str, str] = {}
    for key, value in payload.items.items():
        clean_key = key.strip()
        if not clean_key:
            continue
        item = session.get(Setting, clean_key)
        if item is None:
            item = Setting(key=clean_key, value=value)
            session.add(item)
        else:
            item.value = value
        updated[clean_key] = value

    write_audit_event(
        session=session,
        action="admin_settings_updated",
        user_id=actor.id,
        target="settings",
        details=updated,
        ip_address=request.client.host if request.client else None,
    )

    items = session.scalars(select(Setting).order_by(Setting.key.asc())).all()
    return {"items": {item.key: item.value or "" for item in items}}


@router.get("/audit")
def audit_list(
    page: int = 1,
    per_page: int = 50,
    action: str | None = None,
    _: User = Depends(require_permission("audit:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    page = max(page, 1)
    per_page = min(max(per_page, 1), 200)

    stmt = select(AuditLog)
    count_stmt = select(func.count(AuditLog.id))
    if action:
        stmt = stmt.where(AuditLog.action == action)
        count_stmt = count_stmt.where(AuditLog.action == action)

    total = session.scalar(count_stmt) or 0
    rows = session.scalars(
        stmt.order_by(AuditLog.id.desc()).offset((page - 1) * per_page).limit(per_page)
    ).all()
    pages = max((total + per_page - 1) // per_page, 1)
    items = [
        {
            "id": row.id,
            "user_id": row.user_id,
            "action": row.action,
            "target": row.target,
            "details": row.details,
            "created_at": row.created_at.isoformat() if row.created_at else None,
            "ip_address": row.ip_address,
        }
        for row in rows
    ]
    return {"items": items, "total": int(total), "page": page, "pages": pages}


def _campaign_payload(item: BroadcastCampaign) -> dict[str, Any]:
    return {
        "id": item.id,
        "segment": item.segment,
        "message": item.message,
        "status": item.status,
        "total_targets": item.total_targets,
        "sent_count": item.sent_count,
        "failed_count": item.failed_count,
        "created_by_user_id": item.created_by_user_id,
        "created_at": item.created_at.isoformat() if item.created_at else None,
        "started_at": item.started_at.isoformat() if item.started_at else None,
        "finished_at": item.finished_at.isoformat() if item.finished_at else None,
        "last_error": item.last_error,
    }


@router.get("/broadcasts")
def broadcasts_list(
    limit: int = 100,
    _: User = Depends(require_permission("broadcasts:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    items = broadcast_service.list_campaigns(session=session, limit=limit)
    return {"items": [_campaign_payload(item) for item in items], "total": len(items)}


@router.post("/broadcasts")
def broadcasts_create(
    payload: BroadcastCreateRequest,
    request: Request,
    actor: User = Depends(require_permission("broadcasts:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    try:
        campaign = broadcast_service.create_campaign(
            session=session,
            segment=payload.segment.strip().lower(),
            message=payload.message,
            created_by_user_id=actor.id,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    write_audit_event(
        session=session,
        action="admin_broadcast_created",
        user_id=actor.id,
        target=f"broadcast:{campaign.id}",
        details={"segment": campaign.segment, "total_targets": campaign.total_targets},
        ip_address=request.client.host if request.client else None,
    )
    return _campaign_payload(campaign)


@router.get("/workers/runs")
def workers_runs(
    task_name: str | None = None,
    status_value: str | None = None,
    limit: int = 100,
    _: User = Depends(require_permission("workers:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    stmt = select(WorkerJobRun)
    if task_name:
        stmt = stmt.where(WorkerJobRun.task_name == task_name)
    if status_value:
        stmt = stmt.where(WorkerJobRun.status == status_value)
    rows = session.scalars(
        stmt.order_by(WorkerJobRun.id.desc()).limit(max(1, min(limit, 500)))
    ).all()
    items = [
        {
            "id": row.id,
            "task_name": row.task_name,
            "status": row.status,
            "started_at": row.started_at.isoformat() if row.started_at else None,
            "finished_at": row.finished_at.isoformat() if row.finished_at else None,
            "duration_ms": row.duration_ms,
            "processed_count": row.processed_count,
            "success_count": row.success_count,
            "error_count": row.error_count,
            "details": row.details,
            "error_message": row.error_message,
        }
        for row in rows
    ]
    return {"items": items, "total": len(items)}


@router.get("/workers/dlq")
def workers_dlq(
    task_name: str | None = None,
    limit: int = 100,
    _: User = Depends(require_permission("workers:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    stmt = select(WorkerDeadLetter)
    if task_name:
        stmt = stmt.where(WorkerDeadLetter.task_name == task_name)
    rows = session.scalars(
        stmt.order_by(WorkerDeadLetter.id.desc()).limit(max(1, min(limit, 500)))
    ).all()
    items = [
        {
            "id": row.id,
            "task_name": row.task_name,
            "item_key": row.item_key,
            "payload": row.payload,
            "error_message": row.error_message,
            "attempts": row.attempts,
            "created_at": row.created_at.isoformat() if row.created_at else None,
        }
        for row in rows
    ]
    return {"items": items, "total": len(items)}


@router.get("/bot/overview")
def bot_overview(
    _: User = Depends(require_permission("audit:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    return bot_service.get_admin_overview(session)


@router.get("/bot/activity")
def bot_activity(
    limit: int = 100,
    action: str | None = None,
    _: User = Depends(require_permission("audit:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    items = bot_service.get_admin_activity(session=session, limit=max(1, min(limit, 500)), action=action)
    return {"items": items, "total": len(items)}


@router.get("/bot/settings")
def bot_settings(
    _: User = Depends(require_permission("settings:read")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    return {"items": bot_service.get_admin_settings(session)}


@router.put("/bot/settings")
def bot_settings_update(
    payload: dict[str, Any],
    request: Request,
    actor: User = Depends(require_permission("settings:write")),
    session: Session = Depends(_db_session),
) -> dict[str, Any]:
    items = bot_service.update_admin_settings(
        session=session,
        values=payload,
        ip_address=request.client.host if request.client else None,
    )
    write_audit_event(
        session=session,
        action="admin_bot_settings_updated",
        user_id=actor.id,
        target="bot_settings",
        details=payload,
        ip_address=request.client.host if request.client else None,
    )
    return {"items": items}
