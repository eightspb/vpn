"""Бизнес-логика Telegram Bot MVP."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta
from decimal import Decimal
import json
import logging
import urllib.error
import urllib.request
from typing import Any, Optional

from sqlalchemy import select
from sqlalchemy.orm import Session, selectinload

from backend.bot.fsm import BotState
from backend.bot.router import BotReply, BotRouter
from backend.core.config import get_settings
from backend.integrations.test_payment_provider import TestPaymentProvider
from backend.models.enums import RoleEnum, SubscriptionStatus
from backend.models.peer_device import PeerDevice
from backend.models.plan import PlanOffer
from backend.models.subscription import Subscription, Transaction
from backend.models.telegram_profile import TelegramProfile
from backend.models.user import User
from backend.services.audit_service import write_audit_event

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
    ) -> None:
        if not self._outbound_enabled:
            logger.info(
                "BOT_OUTBOUND_DISABLED chat_id=%s text=%s reply_markup=%s",
                chat_id,
                text,
                bool(reply_markup),
            )
            return
        if not self._token:
            logger.warning("TELEGRAM_BOT_TOKEN is empty, message dropped chat_id=%s", chat_id)
            return
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
        except urllib.error.HTTPError as exc:
            logger.error("Telegram send failed code=%s body=%s", exc.code, exc.read())
        except Exception:
            logger.exception("Telegram send failed")


class BotService:
    """Обработчик telegram update + сценарии оплаты/подписки."""

    def __init__(self, gateway: TelegramGateway, payment_provider: TestPaymentProvider):
        self._gateway = gateway
        self._payment_provider = payment_provider
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

    def confirm_payment(self, session: Session, external_id: str, ip_address: Optional[str], source: str) -> bool:
        transaction = session.scalar(
            select(Transaction).where(
                Transaction.provider == self._payment_provider.provider_name,
                Transaction.external_id == external_id,
            )
        )
        if transaction is None:
            return False
        if transaction.status == "completed":
            return True
        transaction.status = "completed"

        subscription = None
        if transaction.subscription_id is not None:
            subscription = session.get(Subscription, transaction.subscription_id)
        if subscription is None:
            logger.error("transaction %s has no subscription", transaction.id)
            return True

        offer = session.get(PlanOffer, subscription.plan_offer_id)
        if offer is None:
            logger.error("subscription %s has no offer", subscription.id)
            return True

        now = datetime.utcnow()
        subscription.status = SubscriptionStatus.ACTIVE
        subscription.started_at = now
        subscription.expires_at = now + timedelta(days=offer.duration_days)

        write_audit_event(
            session=session,
            action="payment_confirmed",
            user_id=subscription.user_id,
            target=f"transaction:{transaction.id}",
            details={"provider": transaction.provider, "external_id": external_id, "source": source},
            ip_address=ip_address,
        )
        write_audit_event(
            session=session,
            action="subscription_activated",
            user_id=subscription.user_id,
            target=f"subscription:{subscription.id}",
            details={"transaction_id": transaction.id, "plan_offer_id": subscription.plan_offer_id},
            ip_address=ip_address,
        )
        logger.info(
            "event=subscription_activated subscription_id=%s user_id=%s transaction_id=%s",
            subscription.id,
            subscription.user_id,
            transaction.id,
        )

        profile = self._get_profile_by_user_id(session, subscription.user_id)
        if profile:
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
        return BotReply(
            text="Поддержка: напишите @vpn_support (MVP) или ответьте этим сообщением.",
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

        now = datetime.utcnow()
        subscription = Subscription(
            user_id=profile.user_id,
            plan_offer_id=offer.id,
            status=SubscriptionStatus.PENDING,
            started_at=now,
            expires_at=now + timedelta(days=offer.duration_days),
        )
        session.add(subscription)
        session.flush()

        transaction = Transaction(
            subscription_id=subscription.id,
            amount=Decimal(str(offer.price)),
            currency=offer.currency,
            provider=self._payment_provider.provider_name,
            status="pending",
        )
        session.add(transaction)
        session.flush()

        payment = self._payment_provider.create_payment(
            transaction_id=transaction.id,
            amount=str(transaction.amount),
            currency=transaction.currency,
        )
        transaction.external_id = payment.external_id
        profile.fsm_state = BotState.AWAITING_PAYMENT.value
        profile.fsm_payload = json.dumps({"external_id": payment.external_id})
        profile.updated_at = now

        write_audit_event(
            session=session,
            action="payment_created",
            user_id=profile.user_id,
            target=f"transaction:{transaction.id}",
            details={
                "provider": transaction.provider,
                "external_id": payment.external_id,
                "subscription_id": subscription.id,
            },
            ip_address=ip_address,
        )
        logger.info(
            "event=payment_created user_id=%s transaction_id=%s external_id=%s",
            profile.user_id,
            transaction.id,
            payment.external_id,
        )

        return BotReply(
            text=(
                f"Покупка создана: transaction_id={transaction.id}, external_id={payment.external_id}\n"
                f"Ссылка оплаты (test): {payment.payment_url}\n"
                "Для локальной проверки можно отправить POST на /payments/test/confirm/<external_id>.\n"
                f"Или в чате: CONFIRM {payment.external_id}"
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
        payment_provider=TestPaymentProvider(),
    )
