# AGENTS.md — VPN Project

Этот файл автоматически загружается Codex при каждой сессии.

---

## Архитектура

- **VPS1** (входной, Москва): awg0 (тоннель к VPS2) + awg1 (прямые VPN-клиенты)
- **VPS2** (выходной, США): awg0 (конечная точка тоннеля от VPS1) + AdGuard Home DNS (`10.8.0.2:53`, UI `10.8.0.2:3000`)
- **Split tunneling** (опционально): `bash manage.sh deploy --split-tunneling --guard-timeout 300` включает `.ru/.рф/.su` через основной интерфейс VPS1, остальное оставляет через VPS2. DNS upstream остаётся `10.8.0.2:53` на VPS2 (AdGuard Home); DNS-запросы DNAT-ятся на `10.9.0.1`, ответы SNAT-ятся обратно как `10.8.0.2`. Клиентские конфиги и ключи не меняются. Откат: `bash scripts/deploy/rollback-split-tunneling.sh`.
- **Admin panel**: `scripts/admin/admin-server.py` (Flask, port 8081) + `scripts/admin/admin.html` (SPA)
- **Monitor**: `scripts/monitor/monitor-web.sh` (SSH polling → `vpn-output/data.json` каждые 5с)
- **Backend API**: `backend/main.py` (FastAPI)
- **Bot**: `backend/bot/` (Telegram-бот)
- **DB**: SQLite `scripts/admin/admin.db`
- **Domain**: `vpnrus.net`

## Платформа

- macOS + zsh/bash
- Python-окружение для админки: `uv` + `scripts/admin/.venv/`
- Локальный запуск админки выполняется напрямую из macOS shell, без WSL
- Базовый путь для подготовки окружения: `bash manage.sh admin setup`

## Команды

```bash
# Деплой (с управляющего компьютера)
bash manage.sh deploy               # развернуть VPN на VPS1 + VPS2
bash manage.sh deploy --split-tunneling --guard-timeout 300  # split tunneling RU TLD на VPS1
bash manage.sh deploy --split-tunneling --rollback           # аварийный откат

# Тесты
bash tests/test-admin-server.sh     # 104+ тестов для admin-server (0 fail expected)
bash tests/test-backend-health.sh   # smoke-тест backend API
bash tests/test-split-tunneling.sh  # статические тесты split tunneling

# Подготовка и запуск admin-server локально (macOS)
bash manage.sh admin setup
bash manage.sh admin start
```

## Ключевые файлы

| Файл | Назначение |
|------|-----------|
| `scripts/admin/admin-server.py` | Flask-сервер панели управления |
| `scripts/admin/admin.html` | SPA-интерфейс админки |
| `scripts/monitor/monitor-web.sh` | Мониторинг VPS по SSH |
| `scripts/deploy/deploy.sh` | Основной деплой-скрипт |
| `scripts/deploy/deploy-vps1.sh` | Деплой только VPS1 |
| `scripts/deploy/deploy-vps2.sh` | Деплой только VPS2 |
| `scripts/deploy/setup-split-tunneling.sh` | Guarded apply split tunneling на VPS1 |
| `scripts/deploy/rollback-split-tunneling.sh` | Локальный аварийный rollback split tunneling |
| `backend/main.py` | Entry point FastAPI |
| `.env` | Конфиг (IP серверов, SSH ключи) — **не коммитить** |

## Известные нюансы

- **Traffic double-counting**: VPS1 awg0 + VPS2 awg0 измеряют один и тот же тоннель — суммировать нельзя, показывать раздельно по серверам
- **Monitor autostart**: если `data.json` устарел (>30с), `admin-server.py` запускает monitor автоматически при старте
- **Счётчики трафика**: сбрасываются при перезагрузке VPS — метки говорят "с последней перезагрузки", не за всё время
- **Split tunneling firewall**: на VPS1 `FORWARD DROP`; для RU split нужны marked FORWARD правила `awg1 -> MAIN_IF`, иначе `fwmark`/table 100 сами по себе не дадут трафику выйти через VPS1.
- **Split tunneling DNS firewall/routing**: DNS после DNAT обслуживает локальный `dnsmasq` на `10.9.0.1:53`, поэтому нужен явный `INPUT` allow `awg1 -> 10.9.0.1:53` и rule `10.9.0.1 -> 10.9.0.0/24 lookup main`, иначе ответы dnsmasq попадают под `from 10.9.0.0/24 lookup 200` и уходят в awg0.
- **Split rollback**: не полагаться только на удалённый `/usr/local/sbin/split-tunnel-rollback.sh`; локальный `scripts/deploy/rollback-split-tunneling.sh` содержит inline rollback и должен работать даже при частичной установке.

## Правила проекта

### Запрещено

- Выполнять изменение вручную по одной команде, если это можно оформить скриптом
- Проводить деплой или миграции без заранее подготовленного сценария
- Вносить изменения без тестового покрытия затронутой логики
- Менять поведение системы без обновления документации
- Коммитить секреты (`.env`, ключи, токены, приватные сертификаты)

### Обязательный формат изменений

1. **Скрипт как единица поставки** — изменения через готовый скрипт (обновление существующего или новый)
2. **Полный рабочий контур** — подготовка, валидация, выполнение, проверка результата, код выхода
3. **Идемпотентность** — повторный запуск не ломает состояние
4. **Явные pre/post-check** — зависимости до, успешность после

### Definition of Done

- Подготовлен или обновлён рабочий скрипт применения изменения
- Тесты добавлены/обновлены и успешно проходят
- Документация обновлена
- Изменение применено единым запуском скрипта
- Нет критичных регрессий, безопасность не ухудшена

### Приоритеты (при конфликте)

1. Безопасность и целостность данных
2. Воспроизводимость и проверяемость
3. Стабильность эксплуатации
4. Скорость внедрения
