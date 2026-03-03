"""Бизнес-логика Telegram Bot MVP."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
import json
import logging
import urllib.error
import urllib.request
from typing import Any, Optional

from sqlalchemy import func, select
from sqlalchemy.orm import Session, selectinload

from backend.bot.fsm import BotState
from backend.bot.router import BotReply, BotRouter
from backend.core.config import get_settings
from backend.models.audit_log import AuditLog
from backend.models.enums import RoleEnum, SubscriptionStatus, TransactionStatus
from backend.models.peer_device import PeerDevice
from backend.models.plan import PlanOffer
from backend.models.setting import Setting
from backend.models.subscription import Subscription, Transaction
from backend.models.telegram_profile import TelegramProfile
from backend.models.user import User
from backend.services.audit_service import write_audit_event
from backend.services.billing_service import BillingService, build_billing_service

logger = logging.getLogger(__name__)


MAIN_MENU_TEXT = (
    "Главное меню:\n"
    "- Мой профиль\n"
    "- Тарифы\n"
    "- Моя подписка\n"
    "- Поддержка"
)


@dataclass
class TelegramIdentity:
    telegram_id: int
    chat_id: int
    username: Optional[str]
    first_name: Optional[str]
    last_name: Optional[str]


class TelegramGateway:
    """Отправка ответов через Telegram Bot API."""

    def __init__(self, token: Optional[str], outbound_enabled: bool) -> None:
        self._token = token
        self._outbound_enabled = outbound_enabled

    def send_message(
        self,
        chat_id: int,
        text: str,
        reply_markup: dict[str, Any] | None = None,
    ) -> bool:
        if not self._outbound_enabled:
            logger.info(
                "BOT_OUTBOUND_DISABLED chat_id=%s text=%s reply_markup=%s",
                chat_id,
                text,
                bool(reply_markup),
            )
            return True
        if not self._token:
            logger.warning("TELEGRAM_BOT_TOKEN is empty, message dropped chat_id=%s", chat_id)
            return False
        payload_obj: dict[str, Any] = {"chat_id": chat_id, "text": text}
        if reply_markup is not None:
            payload_obj["reply_markup"] = reply_markup
        payload = json.dumps(payload_obj).encode("utf-8")
        url = f"https://api.telegram.org/bot{self._token}/sendMessage"
        request = urllib.request.Request(
            url=url,
            method="POST",
            data=payload,
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=10) as response:
                response.read()
            return True
        except urllib.error.HTTPError as exc:
            logger.error("Telegram send failed code=%s body=%s", exc.code, exc.read())
            return False
        except Exception:
            logger.exception("Telegram send failed")
            return False


class BotService:
    """Обработчик telegram update + сценарии оплаты/подписки."""

    def __init__(self, gateway: TelegramGateway, billing_service: BillingService):
        self._gateway = gateway
        self._billing_service = billing_service
        self._router = self._build_router()

    def _build_router(self) -> BotRouter:
        router = BotRouter()
        router.add(lambda m, _: m.get("text") == "/start", self._handle_start)
        router.add(lambda m, _: m.get("text") == "Мой профиль", self._handle_profile)
        router.add(lambda m, _: m.get("text") == "Тарифы", self._handle_tariffs)
        router.add(lambda m, _: m.get("text") == "Моя подписка", self._handle_subscription)
        router.add(lambda m, _: m.get("text") == "Поддержка", self._handle_support)
        router.add(lambda m, _: m.get("text") == "Назад в меню", self._handle_back_to_menu)
        router.add(lambda m, _: m.get("text", "").startswith("Купить "), self._handle_purchase)
        router.add(
            lambda m, _: m.get("text", "").startswith("CONFIRM "),
            self._handle_local_confirm_command,
        )
        return router

    def process_update(self, session: Session, update: dict[str, Any], ip_address: Optional[str]) -> None:
        message = update.get("message") or {}
        if not message:
            return
        identity = self._extract_identity(message)
        if identity is None:
            return
        if not self._is_bot_enabled(session):
            self._gateway.send_message(
                identity.chat_id,
                self._get_runtime_setting(
                    session,
                    "BOT_MAINTENANCE_TEXT",
                    "Бот временно отключен администратором. Попробуйте позже.",
                ),
            )
            return
        profile = self._get_profile_by_telegram_id(session, identity.telegram_id)
        reply = self._router.dispatch(
            message=message,
            context={"session": session, "identity": identity, "profile": profile, "ip_address": ip_address},
        )
        self._gateway.send_message(
            identity.chat_id,
            reply.text,
            reply_markup=reply.reply_markup,
        )

    def process_payment_webhook(
        self,
        session: Session,
        provider: str,
        payload: dict[str, Any],
        ip_address: Optional[str],
    ) -> bool:
        result = self._billing_service.process_webhook(
            session=session,
            provider=provider,
            payload=payload,
            ip_address=ip_address,
        )
        return result.found

    def confirm_payment(
        self,
        session: Session,
        external_id: str,
        ip_address: Optional[str],
        source: str,
        provider: str = "test",
    ) -> bool:
        result = self._billing_service.confirm_payment(
            session=session,
            provider=provider,
            external_id=external_id,
            ip_address=ip_address,
            source=source,
        )
        if not result.found:
            return False
        transaction = session.get(Transaction, result.transaction_id) if result.transaction_id else None
        if transaction is None or transaction.subscription_id is None:
            return True
        subscription = session.get(Subscription, transaction.subscription_id)
        if subscription is None:
            return True
        profile = self._get_profile_by_user_id(session, subscription.user_id)
        if profile and transaction.status == TransactionStatus.COMPLETED:
            self._gateway.send_message(
                profile.chat_id,
                f"Оплата подтверждена. Подписка активна до {subscription.expires_at:%Y-%m-%d}.",
                reply_markup=self._main_menu_keyboard(),
            )
        return True

    def _handle_start(self, message: dict[str, Any], context: dict[str, Any]) -> BotReply:
        session: Session = context["session"]
        identity: TelegramIdentity = context["identity"]
        ip_address: Optional[str] = context["ip_address"]

        profile = self._get_profile_by_telegram_id(session, identity.telegram_id)
        if profile is None:
            user = self._register_user(session, identity)
            profile = TelegramProfile(
                user_id=user.id,
                telegram_id=identity.telegram_id,
                chat_id=identity.chat_id,
                telegram_username=identity.username,
                first_name=identity.first_name,
                last_name=identity.last_name,
                fsm_state=BotState.MAIN_MENU.value,
            )
            session.add(profile)
            session.flush()
            write_audit_event(
                session=session,
                action="registration",
                user_id=user.id,
                target=f"telegram:{identity.telegram_id}",
                details={"chat_id": identity.chat_id, "telegram_username": identity.username},
                ip_address=ip_address,
            )
            logger.info("event=registration user_id=%s telegram_id=%s", user.id, identity.telegram_id)
        else:
            profile.chat_id = identity.chat_id
            profile.telegram_username = identity.username
            profile.first_name = identity.first_name
            profile.last_name = identity.last_name
            profile.fsm_state = BotState.MAIN_MENU.value
            profile.updated_at = datetime.utcnow()
        return BotReply(
            text=(
                "Вы зарегистрированы.\n"
                "Используйте кнопки меню ниже.\n\n"
                f"{MAIN_MENU_TEXT}"
            ),
            reply_markup=self._main_menu_keyboard(),
        )

    def _handle_profile(self, _message: dict[str, Any], context: dict[str, Any]) -> BotReply:
        session: Session = context["session"]
        identity: TelegramIdentity = context["identity"]
        profile = self._get_profile_by_telegram_id(session, identity.telegram_id)
        if profile is None:
            return BotReply(text="Сначала отправьте /start для регистрации.")
        user = session.get(User, profile.user_id)
        if user is None:
            return BotReply(text="Профиль не найден. Отправьте /start.")
        return BotReply(
            text=(
                f"Профиль:\n"
                f"- user_id: {user.id}\n"
                f"- username: {user.username}\n"
                f"- telegram: {identity.telegram_id}\n\n"
                f"{MAIN_MENU_TEXT}"
            ),
            reply_markup=self._main_menu_keyboard(),
        )

    def _handle_tariffs(self, _message: dict[str, Any], context: dict[str, Any]) -> BotReply:
        session: Session = context["session"]
        identity: TelegramIdentity = context["identity"]
        profile = self._get_profile_by_telegram_id(session, identity.telegram_id)
        if profile is None:
            return BotReply(text="Сначала отправьте /start для регистрации.")
        profile.fsm_state = BotState.VIEWING_TARIFFS.value
        profile.updated_at = datetime.utcnow()

        offers = session.scalars(select(PlanOffer).options(selectinload(PlanOffer.plan))).all()
        if not offers:
            return BotReply(
                text="Тарифы пока не настроены.",
                reply_markup=self._main_menu_keyboard(),
            )
        lines = ["Тарифы (используйте кнопку Купить):"]
        for offer in offers:
            lines.append(
                f"{offer.id}: {offer.plan.name} / {offer.duration_days} дней / {offer.price} {offer.currency}"
            )
        return BotReply(
            text="\n".join(lines),
            reply_markup=self._tariffs_keyboard(offers),
        )

    def _handle_subscription(self, _message: dict[str, Any], context: dict[str, Any]) -> BotReply:
        session: Session = context["session"]
        identity: TelegramIdentity = context["identity"]
        profile = self._get_profile_by_telegram_id(session, identity.telegram_id)
        if profile is None:
            return BotReply(text="Сначала отправьте /start для регистрации.")
        subscription = session.scalar(
            select(Subscription)
            .where(Subscription.user_id == profile.user_id)
            .order_by(Subscription.id.desc())
        )
        if subscription is None:
            return BotReply(
                text="Подписка не найдена. Откройте 'Тарифы' и создайте покупку.",
                reply_markup=self._main_menu_keyboard(),
            )

        status_line = (
            f"Подписка: status={subscription.status.value}, до {subscription.expires_at:%Y-%m-%d}"
        )
        config_line = self._build_config_message(session, profile.user_id, subscription.id)
        return BotReply(
            text=f"{status_line}\n{config_line}\n\n{MAIN_MENU_TEXT}",
            reply_markup=self._main_menu_keyboard(),
        )

    def _handle_support(self, _message: dict[str, Any], _context: dict[str, Any]) -> BotReply:
        session: Session = _context["session"]
        support_contact = self._get_runtime_setting(session, "BOT_SUPPORT_CONTACT", "@vpn_support")
        return BotReply(
            text=f"Поддержка: напишите {support_contact} (MVP) или ответьте этим сообщением.",
            reply_markup=self._main_menu_keyboard(),
        )

    def _handle_back_to_menu(self, _message: dict[str, Any], context: dict[str, Any]) -> BotReply:
        session: Session = context["session"]
        identity: TelegramIdentity = context["identity"]
        profile = self._get_profile_by_telegram_id(session, identity.telegram_id)
        if profile is not None:
            profile.fsm_state = BotState.MAIN_MENU.value
            profile.updated_at = datetime.utcnow()
        return BotReply(text=MAIN_MENU_TEXT, reply_markup=self._main_menu_keyboard())

    def _handle_purchase(self, message: dict[str, Any], context: dict[str, Any]) -> BotReply:
        session: Session = context["session"]
        identity: TelegramIdentity = context["identity"]
        ip_address: Optional[str] = context["ip_address"]
        profile = self._get_profile_by_telegram_id(session, identity.telegram_id)
        if profile is None:
            return BotReply(text="Сначала отправьте /start для регистрации.")

        offer_id_text = message.get("text", "").replace("Купить ", "", 1).strip()
        if not offer_id_text.isdigit():
            return BotReply(text="Неверный формат. Используйте кнопку Купить или 'Купить <offer_id>'.")
        offer = session.get(PlanOffer, int(offer_id_text))
        if offer is None:
            return BotReply(text="Тариф не найден.")

        promocode = None
        provider = self._get_runtime_setting(session, "BOT_PAYMENT_PROVIDER", "test").strip().lower() or "test"
        raw_tail = message.get("text", "").strip().split()
        if len(raw_tail) >= 3 and raw_tail[2].upper().startswith("PROMO="):
            promocode = raw_tail[2][6:]
        checkout = self._billing_service.create_checkout(
            session=session,
            user_id=profile.user_id,
            offer_id=offer.id,
            provider=provider,
            ip_address=ip_address,
            promocode_code=promocode,
            trial=False,
        )
        profile.fsm_state = BotState.AWAITING_PAYMENT.value
        profile.fsm_payload = json.dumps({"external_id": checkout.external_id, "provider": checkout.provider})
        profile.updated_at = datetime.utcnow()

        logger.info(
            "event=payment_created user_id=%s transaction_id=%s external_id=%s",
            profile.user_id,
            checkout.transaction_id,
            checkout.external_id,
        )

        return BotReply(
            text=(
                f"Покупка создана: transaction_id={checkout.transaction_id}, external_id={checkout.external_id}\n"
                f"Ссылка оплаты ({checkout.provider}): {checkout.payment_url}\n"
                "Для локальной проверки можно отправить POST на /payments/test/confirm/<external_id>.\n"
                f"Или в чате: CONFIRM {checkout.external_id}"
            ),
            reply_markup=self._main_menu_keyboard(),
        )

    def _handle_local_confirm_command(
        self, message: dict[str, Any], context: dict[str, Any]
    ) -> BotReply:
        session: Session = context["session"]
        ip_address: Optional[str] = context["ip_address"]
        external_id = message.get("text", "").replace("CONFIRM ", "", 1).strip()
        if not external_id:
            return BotReply(text="Укажите external_id: CONFIRM <external_id>.")
        ok = self.confirm_payment(session, external_id=external_id, ip_address=ip_address, source="telegram")
        if not ok:
            return BotReply(text="Платеж не найден.")
        return BotReply(text="Платеж подтвержден.", reply_markup=self._main_menu_keyboard())

    def _extract_identity(self, message: dict[str, Any]) -> Optional[TelegramIdentity]:
        sender = message.get("from") or {}
        chat = message.get("chat") or {}
        if not sender.get("id") or not chat.get("id"):
            return None
        return TelegramIdentity(
            telegram_id=int(sender["id"]),
            chat_id=int(chat["id"]),
            username=sender.get("username"),
            first_name=sender.get("first_name"),
            last_name=sender.get("last_name"),
        )

    def _register_user(self, session: Session, identity: TelegramIdentity) -> User:
        username_base = f"tg_{identity.telegram_id}"
        username = username_base
        suffix = 1
        while session.scalar(select(User.id).where(User.username == username)) is not None:
            suffix += 1
            username = f"{username_base}_{suffix}"
        user = User(username=username, password_hash="__telegram_auth__", role=RoleEnum.USER)
        session.add(user)
        session.flush()
        return user

    def _get_profile_by_telegram_id(self, session: Session, telegram_id: int) -> Optional[TelegramProfile]:
        return session.scalar(
            select(TelegramProfile).where(TelegramProfile.telegram_id == telegram_id)
        )

    def _get_profile_by_user_id(self, session: Session, user_id: int) -> Optional[TelegramProfile]:
        return session.scalar(select(TelegramProfile).where(TelegramProfile.user_id == user_id))

    def _build_config_message(self, session: Session, user_id: int, subscription_id: int) -> str:
        peer = session.scalar(
            select(PeerDevice)
            .where(PeerDevice.user_id == user_id, PeerDevice.subscription_id == subscription_id)
            .order_by(PeerDevice.id.desc())
        )
        if peer is None:
            return (
                "Конфиг: пока не назначен.\n"
                "TODO: подключить генерацию/выдачу через слой peers_devices."
            )
        if peer.config_file:
            return f"Конфиг: используйте файл {peer.config_file}"
        return "Конфиг: устройство найдено, но путь к конфигу пустой."

    def _main_menu_keyboard(self) -> dict[str, Any]:
        return {
            "keyboard": [
                [{"text": "Мой профиль"}, {"text": "Тарифы"}],
                [{"text": "Моя подписка"}, {"text": "Поддержка"}],
            ],
            "resize_keyboard": True,
            "is_persistent": True,
        }

    def _is_bot_enabled(self, session: Session) -> bool:
        raw = self._get_runtime_setting(session, "BOT_ENABLED", "true")
        return str(raw).strip().lower() not in {"0", "false", "off", "no"}

    def _get_runtime_setting(self, session: Session, key: str, default: str) -> str:
        value = session.scalar(select(Setting.value).where(Setting.key == key))
        if value is None:
            return default
        return str(value)

    def get_admin_overview(self, session: Session) -> dict[str, Any]:
        now = datetime.utcnow()
        since_24h = now - timedelta(hours=24)
        since_30d = now - timedelta(days=30)

        total_users = session.scalar(select(func.count(TelegramProfile.id))) or 0
        new_users_24h = session.scalar(
            select(func.count(TelegramProfile.id)).where(TelegramProfile.created_at >= since_24h)
        ) or 0
        active_subscriptions = session.scalar(
            select(func.count(Subscription.id)).where(Subscription.status == SubscriptionStatus.ACTIVE)
        ) or 0
        pending_subscriptions = session.scalar(
            select(func.count(Subscription.id)).where(Subscription.status == SubscriptionStatus.PENDING)
        ) or 0
        total_transactions = session.scalar(select(func.count(Transaction.id))) or 0
        pending_transactions = session.scalar(
            select(func.count(Transaction.id)).where(Transaction.status == TransactionStatus.PENDING)
        ) or 0
        completed_transactions = session.scalar(
            select(func.count(Transaction.id)).where(Transaction.status == TransactionStatus.COMPLETED)
        ) or 0
        payments_24h = session.scalar(
            select(func.count(Transaction.id)).where(Transaction.created_at >= since_24h)
        ) or 0
        revenue_total = session.scalar(
            select(func.coalesce(func.sum(Transaction.amount), 0)).where(Transaction.status == TransactionStatus.COMPLETED)
        ) or 0
        revenue_30d = session.scalar(
            select(func.coalesce(func.sum(Transaction.amount), 0)).where(
                Transaction.status == TransactionStatus.COMPLETED,
                Transaction.created_at >= since_30d,
            )
        ) or 0

        fsm_rows = session.execute(
            select(TelegramProfile.fsm_state, func.count(TelegramProfile.id)).group_by(TelegramProfile.fsm_state)
        ).all()
        fsm_by_state = {str(state): int(count) for state, count in fsm_rows if state}

        bot_actions = (
            "registration",
            "payment_created",
            "payment_confirmed",
            "subscription_activated",
            "bot_settings_updated",
        )
        bot_events_24h = session.scalar(
            select(func.count(AuditLog.id)).where(
                AuditLog.action.in_(bot_actions),
                AuditLog.created_at >= since_24h,
            )
        ) or 0

        return {
            "stats": {
                "telegram_users_total": int(total_users),
                "telegram_users_new_24h": int(new_users_24h),
                "subscriptions_active": int(active_subscriptions),
                "subscriptions_pending": int(pending_subscriptions),
                "transactions_total": int(total_transactions),
                "transactions_pending": int(pending_transactions),
                "transactions_completed": int(completed_transactions),
                "payments_created_24h": int(payments_24h),
                "revenue_completed_total": str(revenue_total),
                "revenue_completed_30d": str(revenue_30d),
                "bot_events_24h": int(bot_events_24h or 0),
                "fsm_by_state": fsm_by_state,
            },
            "runtime": {
                "bot_enabled": self._is_bot_enabled(session),
                "support_contact": self._get_runtime_setting(session, "BOT_SUPPORT_CONTACT", "@vpn_support"),
                "outbound_enabled_env": bool(get_settings().BOT_OUTBOUND_ENABLED),
                "telegram_token_configured": bool(get_settings().TELEGRAM_BOT_TOKEN),
                "webhook_secret_configured": bool(get_settings().TELEGRAM_WEBHOOK_SECRET_TOKEN),
                "internal_api_token_configured": bool(get_settings().BOT_INTERNAL_API_TOKEN),
            },
        }

    def get_admin_activity(
        self,
        session: Session,
        limit: int = 50,
        action: Optional[str] = None,
    ) -> list[dict[str, Any]]:
        actions = {"registration", "payment_created", "payment_confirmed", "subscription_activated", "bot_settings_updated"}

        stmt = select(AuditLog).where(AuditLog.action.in_(tuple(actions)))
        if action:
            stmt = stmt.where(AuditLog.action == action)
        stmt = stmt.order_by(AuditLog.id.desc()).limit(max(1, min(limit, 500)))
        rows = session.scalars(stmt).all()
        result: list[dict[str, Any]] = []
        for row in rows:
            result.append(
                {
                    "id": row.id,
                    "action": row.action,
                    "user_id": row.user_id,
                    "target": row.target,
                    "details": row.details,
                    "ip_address": row.ip_address,
                    "created_at": row.created_at.isoformat() if row.created_at else None,
                }
            )
        return result

    def get_admin_settings(self, session: Session) -> dict[str, str]:
        defaults = {
            "BOT_ENABLED": "true",
            "BOT_SUPPORT_CONTACT": "@vpn_support",
            "BOT_MAINTENANCE_TEXT": "Бот временно отключен администратором. Попробуйте позже.",
        }
        rows = session.scalars(select(Setting).where(Setting.key.like("BOT_%"))).all()
        result = defaults.copy()
        for row in rows:
            result[row.key] = row.value or ""
        return result

    def update_admin_settings(
        self,
        session: Session,
        values: dict[str, Any],
        ip_address: Optional[str],
    ) -> dict[str, str]:
        allowed = {"BOT_ENABLED", "BOT_SUPPORT_CONTACT", "BOT_MAINTENANCE_TEXT"}
        updated: dict[str, str] = {}
        for key, value in values.items():
            if key not in allowed:
                continue
            val = str(value).strip()
            if key == "BOT_ENABLED":
                val = "true" if val.lower() in {"1", "true", "yes", "on"} else "false"
            if key in {"BOT_SUPPORT_CONTACT", "BOT_MAINTENANCE_TEXT"} and not val:
                continue
            session.merge(Setting(key=key, value=val))
            updated[key] = val
        if updated:
            write_audit_event(
                session=session,
                action="bot_settings_updated",
                user_id=None,
                target="bot_runtime",
                details=updated,
                ip_address=ip_address,
            )
            logger.info("event=bot_settings_updated keys=%s", ",".join(sorted(updated.keys())))
        return self.get_admin_settings(session)

    def _tariffs_keyboard(self, offers: list[PlanOffer]) -> dict[str, Any]:
        rows: list[list[dict[str, str]]] = []
        for offer in offers:
            rows.append([{"text": f"Купить {offer.id}"}])
        rows.append([{"text": "Назад в меню"}])
        return {
            "keyboard": rows,
            "resize_keyboard": True,
            "is_persistent": True,
        }


def build_bot_service() -> BotService:
    settings = get_settings()
    return BotService(
        gateway=TelegramGateway(
            token=settings.TELEGRAM_BOT_TOKEN,
            outbound_enabled=settings.BOT_OUTBOUND_ENABLED,
        ),
        billing_service=build_billing_service(),
    )
