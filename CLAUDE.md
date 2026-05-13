# CLAUDE.md — VPN Project

Этот файл автоматически загружается Claude Code при каждой сессии.

---

## Архитектура

- **VPS1** (входной, Москва): awg0 (тоннель к VPS2) + awg1 (прямые VPN-клиенты)
- **VPS2** (выходной, США): awg0 (конечная точка тоннеля от VPS1)
- **Split tunneling** (опционально, `bash manage.sh deploy --split-tunneling`): на VPS1 поднимается `dnsmasq` (10.9.0.1:53) как DNS-прокси перед AdGuard на VPS2. Он наблюдает за DNS-запросами и автоматически складывает IP `.ru/.рф/.su`-доменов в ipset `ru_subnets`. iptables/mangle маркирует только NEW-коннекты через CONNMARK, policy routing (`fwmark 0x100 → table 100`) направляет их через основной интерфейс VPS1 в обход awg0. Существующие сессии не разрываются, клиентские конфиги не меняются.
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
bash manage.sh deploy                       # развернуть VPN на VPS1 + VPS2
bash manage.sh deploy --with-proxy          # + youtube-proxy
bash manage.sh deploy --split-tunneling     # включить раздельное туннелирование на VPS1
bash manage.sh deploy --split-tunneling --rollback   # полный откат split tunneling

# Тесты
bash tests/test-admin-server.sh     # 104+ тестов для admin-server (0 fail expected)
bash tests/test-backend-health.sh   # smoke-тест backend API
bash tests/test-split-tunneling.sh  # 69 статических тестов артефактов split tunneling

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
| `scripts/deploy/setup-split-tunneling.sh` | Установка раздельного туннелирования (.ru мимо VPN) на VPS1 |
| `scripts/deploy/split-tunneling/` | Артефакты split tunneling: dnsmasq-конфиг, apply/rollback-скрипты, systemd-юниты |
| `scripts/deploy/fix-networkd-routing.sh` | Восстановление `ip rule` (table 200 + split-tunneling) после рестарта networkd |
| `backend/main.py` | Entry point FastAPI |
| `.env` | Конфиг (IP серверов, SSH ключи) — **не коммитить** |

## Известные нюансы

- **Traffic double-counting**: VPS1 awg0 + VPS2 awg0 измеряют один и тот же тоннель — суммировать нельзя, показывать раздельно по серверам
- **Monitor autostart**: если `data.json` устарел (>30с), `admin-server.py` запускает monitor автоматически при старте
- **Счётчики трафика**: сбрасываются при перезагрузке VPS — метки говорят "с последней перезагрузки", не за всё время
- **Split tunneling и счётчики**: при включённом split tunneling VPS1 awg0 показывает только зарубежный трафик (российский идёт через основной интерфейс VPS1 минуя awg0). Чтобы видеть весь клиентский трафик, надо смотреть `awg1` на VPS1.
- **Split tunneling и первый коннект**: первый запрос к новому `.ru`-домену может пройти через VPN (пока dnsmasq не успеет добавить IP в ipset). Последующие — напрямую. Задержка ~50–200мс однократно.
- **Split tunneling зависит от dnsmasq**: если dnsmasq на VPS1 не запущен — DNS у клиентов не работает (так как awg1 DNAT перенаправлен на 10.9.0.1:53). `Restart=always` + healthcheck в apply.sh защищают от этого. Полный откат: `bash manage.sh deploy --split-tunneling --rollback`.

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
