# Minimal PR Plan (Low-Risk)

Цель: закрыть явные локальные риски без изменения внешнего UX деплоя.

## Scope

- Не менять сетевую схему и протоколы.
- Не менять публичные команды `manage.sh`.
- Не делать remote-изменений на VPS в рамках PR.

## Findings (приоритет)

1. `scripts/tools/manage-peers.sh`: используются `info` и `fail`, но функции локально не объявлены.
2. `scripts/tools/generate-all-configs.sh`: присутствует hardcoded `CLIENT_PRIV`.
3. Тесты для peers в основном статические; runtime-ветки с ошибками могут пройти незамеченными.

## PR #1: Stabilize manage-peers runtime

### Changes

- В `manage-peers.sh` заменить вызовы `info`/`fail` на существующие `log`/`err`/`warn`/`ok` (из `lib/common.sh`), либо добавить локальные обёртки.
- Прогнать сценарии `add/batch/list/remove/export/info` в smoke-режиме (с моком SSH или безопасным dry path).

### Validation

```bash
bash -n scripts/tools/manage-peers.sh
bash tests/test-manage-peers.sh
```

## PR #2: Remove hardcoded client key path

### Changes

- В `generate-all-configs.sh` убрать хардкод `CLIENT_PRIV`.
- Источник ключа: `vpn-output/keys.env` (или безопасное явное падение с сообщением, что ключ отсутствует).
- Обновить README секцию по пересборке конфигов.

### Validation

```bash
bash -n scripts/tools/generate-all-configs.sh
bash tests/test-generate-all-configs.sh
```

## PR #3: Add runtime-focused tests

### Changes

- Добавить целевые тесты на runtime-ветки `manage-peers.sh`:
  - обработка неизвестной команды;
  - корректный выход при отсутствующих обязательных входах;
  - отсутствие `command not found` на `info`/`fail`.
- Добавить проверку, что в `generate-all-configs.sh` нет literal-приватного ключа.

### Validation

```bash
bash tests/test-manage-peers.sh
bash tests/test-generate-all-configs.sh
```

## Rollout order

1. PR #1
2. PR #2
3. PR #3

## Rollback

- Откат на уровне отдельных файлов PR-коммита.
- Без вмешательства в deployed VPS.

