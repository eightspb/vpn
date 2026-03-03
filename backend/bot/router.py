"""Простой message router для MVP-бота."""

from collections.abc import Callable
from dataclasses import dataclass
from typing import Any


@dataclass
class BotReply:
    text: str
    reply_markup: dict[str, Any] | None = None


Handler = Callable[[dict[str, Any], dict[str, Any]], BotReply]
Matcher = Callable[[dict[str, Any], dict[str, Any]], bool]


@dataclass
class Route:
    matcher: Matcher
    handler: Handler


class BotRouter:
    """Последовательно проверяет роуты и вызывает первый матч."""

    def __init__(self) -> None:
        self._routes: list[Route] = []

    def add(self, matcher: Matcher, handler: Handler) -> None:
        self._routes.append(Route(matcher=matcher, handler=handler))

    def dispatch(self, message: dict[str, Any], context: dict[str, Any]) -> BotReply:
        for route in self._routes:
            if route.matcher(message, context):
                return route.handler(message, context)
        return BotReply(text="Команда не распознана. Используйте /start или кнопки меню.")
