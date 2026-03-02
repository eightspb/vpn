# ONBOARDING MEMO: VPN Project

## 1. Что это за проект

Автоматизированный деплой двухузловой VPN-схемы:

- Клиент -> VPS1 (вход, AmneziaWG)
- VPS1 -> VPS2 (туннель)
- VPS2 -> Интернет
- Опционально: `youtube-proxy` (DNS/HTTPS фильтрация)

Единая точка входа: `manage.sh`.

## 2. Минимальный preflight перед любой работой

1. Проверить, что `.env` заполнен.
2. Проверить, что SSH-ключи доступны (обычно `.ssh/` в корне проекта).
3. Быстрый sanity-check:

```bash
bash manage.sh help
bash manage.sh audit
```

## 3. Ежедневные команды (операторский минимум)

### Деплой

```bash
# Полный деплой
bash manage.sh deploy

# Полный деплой + youtube-proxy
bash manage.sh deploy --with-proxy --remove-adguard

# Точечный деплой
bash manage.sh deploy --vps1
bash manage.sh deploy --vps2
bash manage.sh deploy --proxy --remove-adguard
```

### Мониторинг

```bash
# TUI
bash manage.sh monitor

# Web dashboard
bash manage.sh monitor --web
```

### Управление пирами

```bash
# Добавить устройство
bash manage.sh peers add --name phone --type phone --qr

# Список
bash manage.sh peers list

# Удалить
bash manage.sh peers remove --name phone
```

### Админ-панель

```bash
bash manage.sh admin setup
bash manage.sh admin start
bash manage.sh admin status
bash manage.sh admin stop
```

## 4. Основные директории

- `scripts/deploy/` — деплой и hardening
- `scripts/monitor/` — realtime/web мониторинг
- `scripts/tools/` — диагностика, оптимизация, peers, аудит
- `scripts/admin/` — Flask API + web UI админки
- `youtube-proxy/` — Go-сервис DNS/HTTPS фильтра
- `tests/` — shell/ps1 тесты
- `vpn-output/` — сгенерированные конфиги и ключевые артефакты

## 5. Что важно не ломать

1. Контракты CLI в `manage.sh`.
2. Формат `vpn-output/keys.env` и клиентских `.conf`.
3. SSH-поток деплоя (key/pass, WSL/Windows path handling).
4. Безопасность по умолчанию (`accept-new`, hardening, отсутствие секретов в VCS).

## 6. Быстрый incident flow

1. Диагностика:

```bash
bash scripts/tools/diagnose.sh
```

2. Авто-ремонт:

```bash
bash scripts/tools/diagnose.sh --fix
```

3. Проверка цепочки:

```bash
bash manage.sh check
```

4. Если сломаны локальные клиентские конфиги (Windows):

```powershell
powershell -ExecutionPolicy Bypass -File scripts/windows/repair-local-configs.ps1
```

## 7. Правило внесения изменений

Любое изменение делается как: скрипт + тест + обновление документации.

