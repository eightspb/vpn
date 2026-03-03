"""FSM для Telegram bot MVP."""

from enum import Enum


class BotState(str, Enum):
    MAIN_MENU = "main_menu"
    VIEWING_TARIFFS = "viewing_tariffs"
    AWAITING_PAYMENT = "awaiting_payment"
