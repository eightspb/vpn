# План Рефакторинга: Готовые Промпты Для Cursor

Этот файл содержит готовые промпты для поэтапной эволюции проекта `vpn`.
Каждый этап можно запускать отдельно в параллельном агенте.

## Как использовать

1. Создайте отдельную ветку под каждый этап (`refactor/stage-0`, `refactor/stage-1`, ...).
2. Копируйте промпт этапа целиком в Cursor.
3. После выполнения этапа проверяйте `Definition of Done`.
4. Не смешивайте этапы в одном PR.

---

## Этап 0. Foundation и декомпозиция монолита

### Промпт для Cursor

```text
Ты работаешь в репозитории C:\WORK_MICS\vpn.

Задача этапа: подготовить foundation для новой модульной архитектуры backend без поломки текущего функционала.

Контекст:
- Сейчас есть рабочий Flask-монолит: scripts/admin/admin-server.py и scripts/admin/admin.html.
- Нужен новый каркас backend, куда позже переедут bot/admin/billing/integration слои.
- На этом этапе нельзя ломать текущие команды manage.sh admin и текущую админку.

Что нужно сделать:
1) Создать новый каталог backend/ со структурой:
   - backend/api/
   - backend/core/
   - backend/services/
   - backend/repositories/
   - backend/models/
   - backend/integrations/
   - backend/workers/
2) Поднять базовый FastAPI app с endpoint:
   - GET /health
   - GET /ready
   - GET /api/v1/meta (версия/окружение)
3) Добавить базовую конфигурацию через .env:
   - APP_ENV, APP_HOST, APP_PORT
   - DATABASE_URL
   - REDIS_URL
   - TELEGRAM_BOT_TOKEN (пока может быть пустой)
4) Добавить docker-compose для локального запуска нового backend + postgres + redis
   (не трогая существующие deploy-скрипты).
5) Добавить минимальный README раздел:
   - как поднять новый backend локально
   - как проверить health endpoints.
6) Добавить базовые автотесты на /health и /ready.

Ограничения:
- Не удалять и не переписывать scripts/admin/admin-server.py на этом этапе.
- Не менять публичное поведение текущей админки.
- Делать маленькие, читаемые модули; без гигантских файлов.

Артефакты:
- Новый backend skeleton.
- docker-compose для нового стека.
- Обновлённая документация.
- Тесты, проходящие локально.

Definition of Done:
- backend запускается локально одной командой.
- /health и /ready отвечают 200.
- Текущий manage.sh admin start продолжает работать без регрессий.

В конце:
1) Покажи список изменённых файлов.
2) Дай команды запуска и проверки.
3) Отдельно укажи потенциальные риски следующего этапа.
```

---

## Этап 1. Домен данных и миграции

### Промпт для Cursor

```text
Ты работаешь в репозитории C:\WORK_MICS\vpn.

Задача этапа: внедрить новую доменную модель данных в Postgres и миграцию из текущих источников (SQLite + peers.json).

Цель:
- Подготовить таблицы и миграции для будущего bot/admin/billing.
- Сделать безопасный import из scripts/admin/admin.db и vpn-output/peers.json.

Нужно реализовать:
1) SQLAlchemy модели + Alembic миграции для сущностей:
   - users
   - roles (или role enum)
   - plans
   - plan_offers
   - subscriptions
   - transactions
   - settings
   - audit_log
   - peers_devices (связка VPN peer и подписки/пользователя)
2) Упрощённая тарифная модель:
   - plan.kind: UNLIMITED|TRAFFIC|DEVICES
   - plan_offers.duration_days: 30/90/365
   - одна валюта в MVP
3) Миграционный скрипт:
   - читает scripts/admin/admin.db
   - читает vpn-output/peers.json
   - переносит данные idempotent-режимом (повторный запуск безопасен)
4) CLI команда миграции (например scripts/migrate_to_pg.sh или python module).
5) Отчёт валидации миграции:
   - количество пользователей/пиров до и после
   - список записей, которые не удалось перенести (если есть).

Ограничения:
- Не ломать текущий SQLite runtime.
- Не удалять старые данные.
- Все миграции должны быть воспроизводимыми.

Артефакты:
- Alembic init + ревизии.
- Модели и репозитории (минимальный слой).
- Скрипт миграции + документация запуска.

Definition of Done:
- alembic upgrade head выполняется успешно.
- миграция из SQLite и peers.json выполняется без падений.
- повторный запуск мигратора не создает дубли.

В конце:
1) Покажи команды для запуска миграции.
2) Приведи пример вывода валидационного отчёта.
3) Отдельно перечисли, какие поля пока не мигрируются и почему.
```

---

## Этап 2. Telegram Bot MVP

### Промпт для Cursor

```text
Ты работаешь в репозитории C:\WORK_MICS\vpn.

Задача этапа: реализовать Telegram Bot MVP как отдельный сервис, интегрированный с новой БД.

MVP-функции бота:
1) /start: регистрация пользователя
2) Главное меню:
   - Мой профиль
   - Тарифы
   - Моя подписка
   - Поддержка
3) Просмотр тарифов (из plans + plan_offers)
4) Создание покупки через временный test payment provider
5) Подтверждение оплаты (mock webhook / internal confirm)
6) Активация подписки и привязка к пользователю
7) Выдача конфигурации (через существующий слой peers или заглушку с понятным TODO)

Технические требования:
- Webhook endpoint с secret token verification.
- Базовая FSM/router структура.
- Логи и audit события для:
  - registration
  - payment_created
  - payment_confirmed
  - subscription_activated
- Конфиг через .env.

Ограничения:
- Не внедрять сразу сложные промокоды/рефералки/мультиязычность.
- Не ломать текущую админку.

Артефакты:
- bot service code
- webhook endpoint
- test payment provider
- базовые тесты happy path
- README раздел “как подключить Telegram webhook локально/на сервере”.

Definition of Done:
- Пользователь проходит путь start -> тариф -> оплата(mock) -> активная подписка.
- Все ключевые действия логируются и пишутся в audit.
- Бот поднимается отдельно от старой админки.

В конце:
1) Покажи минимальный e2e сценарий проверки.
2) Дай команды для локального запуска бота.
3) Опиши, где именно в коде подключен test payment provider.
```

---

## Чеклист Перед Стартом Этапа 2

Этот чеклист обязателен перед запуском `refactor/stage-2-bot-mvp`.

1. PostgreSQL реально доступен и выбран один источник (без конфликтов портов).
2. `DATABASE_URL` в `.env` использует формат `postgresql+psycopg2://...`.
3. Миграции применены:
   - `backend\.venv\Scripts\python -m alembic upgrade head`
4. Импорт данных из `admin.db` и `peers.json` выполнен:
   - dry-run и реальный прогон без ошибок.
5. Повторный запуск мигратора идемпотентен (`imported=0`).
6. Проверены таблицы и данные:
   - `users`, `plans`, `plan_offers`, `peers_devices`, `settings`, `audit_log`.
7. Пройден backend smoke:
   - `bash tests/test-backend-health.sh`
   - `bash tests/test-migrate-to-pg.sh`
8. Зафиксированы параметры локального стенда в README/заметке:
   - какой порт PG используется,
   - какой `DATABASE_URL`,
   - какие команды запуска валидны.

### Быстрый SQL smoke-check (копипаст)

```text
@'
from sqlalchemy import create_engine, text
from dotenv import load_dotenv
import os

load_dotenv('.env', override=True)
engine = create_engine(os.getenv('DATABASE_URL'))

checks = {
    "users": "select count(*) from users",
    "plans": "select count(*) from plans",
    "plan_offers": "select count(*) from plan_offers",
    "peers_devices": "select count(*) from peers_devices",
    "settings": "select count(*) from settings",
    "audit_log": "select count(*) from audit_log",
    "alembic_version": "select version_num from alembic_version",
}

with engine.connect() as conn:
    for name, query in checks.items():
        print(name, conn.execute(text(query)).fetchall())
'@ | backend\.venv\Scripts\python -
```

### Gate Для Перехода К Этапу 2

Переходим к `stage-2-bot-mvp` только если:
1. Все пункты чеклиста выше закрыты.
2. Нет ошибок в Alembic и миграторе.
3. Данные в PG подтверждены SQL-проверкой.

---

## Этап 3. Новая Admin API + адаптация текущей web-админки

### Промпт для Cursor

```text
Ты работаешь в репозитории C:\WORK_MICS\vpn.

Задача этапа: перевести админку на новый backend API, сохранив текущий web-интерфейс максимально безболезненно.

Цели:
- Сделать полноценные admin endpoints в новом backend.
- Подключить существующий admin.html к новому API.
- Сохранить текущие операции peer-management и мониторинга.

Нужно сделать:
1) Реализовать Admin API (v1):
   - auth/login, auth/logout, auth/me
   - users CRUD (минимум list/get/update block/unblock)
   - plans CRUD
   - offers CRUD (30/90/365)
   - subscriptions list/get/update
   - transactions list/get
   - settings get/update
2) Добавить RBAC:
   - owner/admin/operator/readonly
3) Аудит админ-действий в audit_log.
4) Создать совместимый API-адаптер для текущего scripts/admin/admin.html
   (или аккуратно обновить frontend fetch-слой).
5) Сохранить мониторинговые данные через существующие источники
   (scripts/monitor/*), без полной переписи мониторинга.

Ограничения:
- Не удалять старую админку до полной проверки.
- Не ломать действующие команды manage.sh admin.

Артефакты:
- admin endpoints
- сессии/авторизация
- RBAC
- адаптация admin.html к новому API

Definition of Done:
- Основные админ-сценарии работают через новый backend.
- Роли ограничивают доступ корректно.
- Все мутации пишутся в audit.

В конце:
1) Перечисли поддержанные админ-сценарии.
2) Покажи, какие API старого Flask пока не перенесены.
3) Дай чек-лист ручного smoke теста админки.
```

---

## Чеклист Перед Стартом Этапа 3

Этот чеклист обязателен перед запуском `refactor/stage-3-admin-api`.

1. Stage 1 полностью закрыт (миграции, импорт, идемпотентность, SQL-проверка).
2. Stage 2 не блокирует schema-contract:
   - бот не вносит breaking-изменения в `users/subscriptions/transactions`.
3. Зафиксирован API baseline текущей админки:
   - список используемых `admin.html` endpoint'ов,
   - какие payload/response ожидает frontend.
4. Подготовлен mapping old->new endpoints:
   - что переносится 1:1,
   - что временно идет через adapter layer.
5. Проверена auth-модель:
   - текущая cookie/session схема не ломает UI,
   - есть план миграции auth без forced logout на каждом рестарте.
6. Проверена совместимость мониторинга:
   - `monitoring/data` и `monitoring/peers` остаются доступными,
   - нет деградации по текущим dashboards.
7. Согласованы роли RBAC:
   - `owner/admin/operator/readonly`,
   - какие действия запрещены каждой роли.
8. Подготовлен fallback:
   - быстрый переключатель на старый Flask admin backend при регрессии.

### Контрольный Prompt Для Агента Этапа 3 (добавить в конец задания)

```text
Перед реализацией:
1) Сними текущий контракт admin frontend -> backend (все fetch URL, методы, payload, response).
2) Составь таблицу совместимости old API -> new API.
3) Реализуй adapter/compat слой для неподдержанных endpoint'ов.

После реализации:
1) Прогони smoke-сценарии: login/logout, peers list, peer edit, settings update, monitoring view.
2) Покажи список endpoint'ов, которые ещё работают через legacy backend.
3) Докажи, что rollback на старый backend возможен одной операцией конфигурации.
```

### Gate Для Перехода К Этапу 4

Переходим к `stage-4-billing-v2` только если:
1. Ключевые админ-сценарии работают на новом API без критических регрессий.
2. Есть рабочий rollback на legacy admin backend.
3. RBAC и аудит мутаций проверены вручную и тестами.

---

## Этап 4. Billing v2 (после MVP)

### Промпт для Cursor

```text
Ты работаешь в репозитории C:\WORK_MICS\vpn.

Задача этапа: сделать production-ориентированный billing слой поверх MVP.

Нужно реализовать:
1) PaymentGateway abstraction:
   - общий интерфейс create_payment / handle_webhook
   - подключить минимум 2 провайдера (или 1 реальный + 1 mock)
2) Транзакции:
   - статусы pending/completed/canceled/failed/refunded
   - идемпотентная обработка вебхуков
   - защита от повторных callback
3) Trial v1:
   - один trial offer
   - ограничения антиабуза (по user, по периоду)
4) Promocode v1:
   - фикс или процент
   - срок действия
   - лимит использований
5) Отчеты в админке:
   - список транзакций
   - фильтры по статусу/провайдеру/периоду.

Ограничения:
- Не усложнять тарифную модель beyond MVP.
- Все платежные операции должны быть traceable через audit/logs.

Артефакты:
- billing domain services
- webhook handlers
- idempotency guard
- промокоды v1

Definition of Done:
- webhook можно безопасно отправлять повторно без дублей активаций.
- транзакции корректно переходят по статусам.
- админка показывает актуальные транзакции.

В конце:
1) Покажи state machine по статусам транзакций.
2) Перечисли меры идемпотентности и anti-double-charge.
3) Дай тест-кейсы для платежных провайдеров.
```

---

## Этап 5. Notifications + Worker automation

### Промпт для Cursor

```text
Ты работаешь в репозитории C:\WORK_MICS\vpn.

Задача этапа: внедрить фоновые задачи и автоматические уведомления.

Нужно сделать:
1) Worker + scheduler (единый выбранный стек).
2) Периодические задачи:
   - notify before expiration (например за 3/1 день)
   - notify expired
   - cleanup stale records
   - sync subscription states с VPN peer state
3) Broadcast v1:
   - отправка по сегментам (all/active/expired)
   - журнал рассылок
4) Retry + DLQ стратегия:
   - ограничение количества повторов
   - сохранение ошибок обработки.
5) Метрики и логи worker задач.

Ограничения:
- Не отправлять дубли уведомлений.
- Каждая задача должна быть идемпотентной.

Артефакты:
- worker service
- scheduler config
- notifications service
- broadcast service

Definition of Done:
- задачи стабильно выполняются по расписанию.
- уведомления не дублируются при ретраях.
- есть наблюдаемость по ошибкам и latency задач.

В конце:
1) Покажи список cron/interval задач.
2) Дай примеры логов успешной и неуспешной задачи.
3) Опиши стратегию retry/backoff.
```

---

## Этап 6. Hardening и release

### Промпт для Cursor

```text
Ты работаешь в репозитории C:\WORK_MICS\vpn.

Задача этапа: довести новую архитектуру до production-ready состояния.

Нужно выполнить:
1) Security hardening:
   - rate limiting auth/payment/webhook endpoints
   - secure session/cookie settings
   - CSRF защита для админки
   - секреты только из env/secret store
2) Observability:
   - structured logs
   - error tracking (например Sentry)
   - метрики (prometheus endpoint)
3) Backup/restore:
   - backup postgres/redis
   - проверяемая restore процедура
4) Release process:
   - миграции при деплое
   - rollback план
   - smoke tests после релиза
5) Документация runbook:
   - инциденты платежей
   - инциденты webhook
   - деградация worker.

Ограничения:
- Никаких breaking changes без миграционного плана.
- Все критичные изменения должны иметь rollback шаг.

Артефакты:
- security checklist
- release checklist
- backup/restore scripts
- runbook docs

Definition of Done:
- проведён dry-run релиза.
- есть рабочий rollback сценарий.
- базовые security пункты закрыты и задокументированы.

В конце:
1) Дай финальный production readiness checklist.
2) Укажи остаточные риски и технический долг.
3) Приведи пошаговый план релиза на 1 страницу.
```

---

## Рекомендуемый порядок запуска этапов

1. Этап 0 и Этап 1 запускать первыми (можно параллельно в разных ветках).
2. Потом Этап 2 и Этап 3.
3. Затем Этап 4.
4. После этого Этап 5.
5. Финализировать Этапом 6.

## Именование веток (рекомендация)

- `refactor/stage-0-foundation`
- `refactor/stage-1-data-migrations`
- `refactor/stage-2-bot-mvp`
- `refactor/stage-3-admin-api`
- `refactor/stage-4-billing-v2`
- `refactor/stage-5-workers-notifications`
- `refactor/stage-6-hardening-release`

---

## Stage 3 Completion Record (2026-03-03)

Статус: `DONE` (этап закрыт как рабочий инкремент).

Что подтверждено:
1. Применены миграции до `head` (включая Stage 3):
   - `004_stage3_rbac_roles_and_blocking`
   - `005_stage3_peer_device_fields`
2. Новый backend поднят отдельно от legacy admin backend.
3. Реализован `Admin API v1` (`/api/v1/admin/*`) + RBAC роли:
   - `owner`, `admin`, `operator`, `readonly`
4. `peers/monitoring` работают через нативные endpoints нового backend.
5. `scripts/admin/admin.html` переключён на `api/v1/admin` через слой маппинга URL.
6. Аудит мутаций включён для ключевых admin-операций.
7. Пройдены smoke-тесты:
   - `tests/test-admin-v1-happy-path.sh`
   - `tests/test-admin-rbac-smoke.sh`

### Минимальный ручной UI smoke-чеклист (5-10 минут)

1. Логин:
   - production smoke: открыть `https://vpnrus.net/admin.html`,
   - локальный smoke (опционально): `http://127.0.0.1:8081/admin.html`,
   - войти под `owner/admin`.
2. Dashboard:
   - загрузились summary/cards без JS ошибок в консоли.
3. Peers:
   - открыть список пиров,
   - создать тестовый peer,
   - открыть edit modal и изменить `group/status`,
   - скачать config.
4. Settings:
   - изменить `DNS` или `Jc`,
   - перезагрузить страницу, убедиться что значение сохранилось.
5. Monitoring:
   - открываются `monitoring/data` и `monitoring/peers` в UI без 401/500.
6. RBAC:
   - под `readonly` убедиться, что записи доступны только read-only,
   - попытка мутации возвращает запрет.
7. Audit:
   - в audit видны действия: login, peer update/create, settings update.

### Rollback (оперативный fallback)

Если найдена регрессия в прод-сценарии:
1. Переключить frontend/backend на legacy admin backend.
2. Оставить новый backend запущенным только для диагностики.
3. Зафиксировать endpoint + payload, на котором воспроизводится регрессия.
