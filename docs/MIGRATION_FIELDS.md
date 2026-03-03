# Миграция в Postgres — поля и ограничения

## Какие поля пока не мигрируются и почему

### Из admin.db (таблица peers)

| Поле | Причина |
|------|---------|
| `mode` | В peers_devices нет — MVP использует `status` (active). При необходимости добавить отдельно. |
| `preshared_key` | Не критично для MVP; можно добавить в следующей ревизии. |
| `expiry_date` | Логика подписок (subscriptions.expires_at) заменит её. |
| `group_name` | Нет групповой модели в MVP. |
| `traffic_limit_mb` | Есть в plans; на уровне peer не дублируем. |
| `config_version` | Версионирование конфигов — отдельная задача. |
| `config_download_count` | Аналитика — отдельная задача. |
| `last_config_downloaded_at` | Аналитика — отдельная задача. |
| `last_downloaded_config_version` | Аналитика — отдельная задача. |
| `updated_at` | Не используется в MVP. |

### Из peers.json

Мигрируются: `name`, `ip`, `type`, `public_key`, `private_key`, `created`, `config_file`.

Дополнительные поля в JSON (если появятся) потребуют обновления скрипта.

### users

Все поля мигрируются. `role` назначается по умолчанию: `admin` → ADMIN, остальные → USER.

### audit_log

`user_id` мигрируется как есть. После миграции ID пользователей в PG могут отличаться — привязка к старым ID сохраняется, но новые записи будут использовать PG user_id.
