# Patch Plan: Security + Efficiency (No-Deploy-Risk)

Этот план разбит на безопасные этапы так, чтобы не ломать текущий деплой и запуск VPN.

## Принципы выполнения

- Меняем только локальный код и тесты, без удалённых изменений на VPS.
- Каждый этап завершается отдельной проверкой тестами.
- До этапа 4 не трогаем критичный path деплоя (`deploy*.sh` поведение остаётся прежним).

## Этап 1 — Baseline аудит и контроль regressions

**Цель:** добавить постоянный контроль рисков в текущий workflow.

**Файлы:**
- `scripts/tools/audit-security-efficiency.sh` (новый)
- `tests/test-audit-security-efficiency.sh` (новый)
- `manage.sh` (новая команда `audit`)
- `README.md` (документация запуска)

**Изменения:**
- Новый read-only аудит скрипт с severity (`critical/high/medium/low`).
- Опциональный `--with-servers` для read-only SSH проверок.
- Режим `--strict` для fail в CI при критичных/высоких рисках.

**Проверка:**
- `bash tests/test-audit-security-efficiency.sh`
- `bash manage.sh audit`

## Этап 2 — Безопасность админ-панели (минимальный риск runtime)

**Цель:** закрыть критичные риски без изменения deploy-флоу VPN.

**Файлы:**
- `scripts/admin/admin-server.py`
- `scripts/admin/admin.html`
- `tests/test-admin-api.sh`
- `tests/test-admin-server.sh`
- `README.md`

**Изменения:**
- Убрать `auth_required_or_local` с mutating API (оставить только read-only monitoring).
- В prod: fail-fast при отсутствии `ADMIN_SECRET_KEY`.
- Перейти на cookie-only auth (убрать `localStorage` токен).
- Ограничить CORS whitelist-ом.

**Проверка:**
- `bash tests/test-admin-server.sh`
- `bash tests/test-admin-api.sh`

## Этап 3 — SSH trust и hardening operational scripts

**Цель:** убрать MITM-риски и небезопасные практики SSH.

**Файлы:**
- `scripts/monitor/monitor-web.sh`
- `scripts/monitor/monitor-realtime.sh`
- `scripts/tools/diagnose.sh`
- `scripts/tools/add_phone_peer.sh`
- `scripts/tools/repair-vps1.sh`
- `scripts/tools/generate-all-configs.sh`
- `scripts/admin/admin-server.py`
- соответствующие `tests/test-*.sh`

**Изменения:**
- `StrictHostKeyChecking=no` -> `accept-new` (или pinned host keys).
- убрать `UserKnownHostsFile=/dev/null`.
- для Paramiko: убрать `AutoAddPolicy`.

**Проверка:**
- `bash tests/test-monitor-web.sh`
- `bash tests/test-admin-server.sh`
- `bash manage.sh audit --strict`

## Этап 4 — Безопасный рефактор deploy-SSH (высокая аккуратность)

**Цель:** убрать `eval "$(ssh_cmd ...)"` без изменения внешнего интерфейса.

**Файлы:**
- `scripts/deploy/deploy.sh`
- `scripts/deploy/deploy-vps1.sh`
- `scripts/deploy/deploy-vps2.sh`
- `lib/common.sh`
- `tests/test-phase*.sh`, `tests/test-security-harden.sh`

**Изменения:**
- Перейти на вызов ssh/scp через массивы аргументов.
- Сохранить текущий CLI и совместимость с `.env`.

**Проверка:**
- `bash tests/test-phase2.sh`
- `bash tests/test-phase3.sh`
- `bash tests/test-phase4.sh`
- `bash tests/test-phase5.sh`

## Этап 5 — Эффективность мониторинга и proxy service hardening

**Цель:** уменьшить нагрузку и повысить операционную устойчивость.

**Файлы:**
- `scripts/monitor/monitor-web.sh`
- `scripts/monitor/monitor-realtime.sh`
- `scripts/deploy/deploy-proxy.sh`
- `youtube-proxy/internal/proxy/proxy.go`
- `youtube-proxy/config.yaml`
- профильные тесты

**Изменения:**
- Поднять default polling interval (5-10s), добавить adaptive backoff.
- Ограничить upstream host allowlist в proxy.
- Ужесточить `youtube-proxy.service` (non-root user + systemd sandbox).

**Проверка:**
- `bash tests/test-monitor-web.sh`
- `bash tests/test-proxy-fix.sh`
- `bash manage.sh audit --with-servers`

## Rollback-стратегия

- Этапы 1-3 откатываются file-level revert без влияния на deployed VPS.
- Этап 4 делать отдельным PR/коммитом с полным пакетом тестов.
- Этап 5 включать feature-flags/конфиг-флаги, чтобы иметь быстрый fallback.
