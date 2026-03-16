# CLAUDE.md — VPN Project

Этот файл автоматически загружается Claude Code при каждой сессии.

---

## Архитектура

- **VPS1** (входной, Москва): awg0 (тоннель к VPS2) + awg1 (прямые VPN-клиенты) + Cloak (опц.)
- **VPS2** (выходной, США): awg0 (конечная точка тоннеля от VPS1)
- **Cloak** (опционально): TLS-маскировка трафика на VPS1, провайдер видит HTTPS к yandex.ru
- **Admin panel**: `scripts/admin/admin-server.py` (Flask, port 8081) + `scripts/admin/admin.html` (SPA)
- **Monitor**: `scripts/monitor/monitor-web.sh` (SSH polling → `vpn-output/data.json` каждые 5с)
- **Backend API**: `backend/main.py` (FastAPI)
- **Bot**: `backend/bot/` (Telegram-бот)
- **DB**: SQLite `scripts/admin/admin.db`
- **Domain**: `vpnrus.net`

## Платформа

- Windows 11 + Git Bash + WSL2
- Python venv: `scripts/admin/.venv/` (WSL-based, Python 3.10)
- `monitor-web.sh` запускается в WSL bash; `admin-server.py` — в Windows Python
- Windows Python **не** принимает MSYS-пути (`/c/...`) в `open()` — использовать `python -m py_compile` вместо `ast.parse(open(...))`
- Для автозапуска monitor из Windows Python: `["wsl", "bash", "/mnt/c/path/to/script.sh"]`

## Команды

```bash
# Деплой (с управляющего компьютера)
bash manage.sh deploy               # развернуть VPN на VPS1 + VPS2
bash manage.sh deploy --with-proxy  # + youtube-proxy
bash manage.sh deploy --with-cloak  # + TLS-маскировка (Cloak, SNI=yandex.ru)
bash manage.sh deploy --with-cloak --fake-domain mail.ru  # маскировка под другой домен
bash scripts/deploy/deploy-cloak.sh --vps1-ip IP --vps1-key KEY  # только Cloak

# Тесты
bash tests/test-admin-server.sh     # 104+ тестов для admin-server (0 fail expected)
bash tests/test-backend-health.sh   # smoke-тест backend API

# Запуск admin-server локально (Windows)
source scripts/admin/.venv/bin/activate
python scripts/admin/admin-server.py
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
| `scripts/deploy/deploy-proxy.sh` | Деплой youtube-proxy |
| `scripts/deploy/deploy-cloak.sh` | Деплой Cloak TLS-маскировки (SNI yandex.ru) |
| `backend/main.py` | Entry point FastAPI |
| `.env` | Конфиг (IP серверов, SSH ключи) — **не коммитить** |

## Известные нюансы

- **Traffic double-counting**: VPS1 awg0 + VPS2 awg0 измеряют один и тот же тоннель — суммировать нельзя, показывать раздельно по серверам
- **Monitor autostart**: если `data.json` устарел (>30с), `admin-server.py` запускает monitor автоматически при старте
- **Счётчики трафика**: сбрасываются при перезагрузке VPS — метки говорят "с последней перезагрузки", не за всё время
- **Cloak TLS-маскировка**: опционально оборачивает AmneziaWG в TLS с SNI=yandex.ru. Провайдер видит обычный HTTPS. Клиенту нужен ck-client + Endpoint=127.0.0.1:1984. Порт 443 TCP на VPS1
- **Cloak vs AmneziaWG Junk**: Junk обфусцирует пакеты (DPI не распознаёт WG), Cloak маскирует весь трафик под HTTPS. Можно использовать оба одновременно

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
