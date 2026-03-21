#!/usr/bin/env bash
# =============================================================================
# cloak-rotate-client.sh — ротация SNI домена на клиенте Cloak
#
# Запускается на клиентском устройстве. Меняет ServerName в ck-client.json
# и перезапускает ck-client. Провайдер видит новый SNI.
#
# ServerName (клиент) НЕ обязан совпадать с RedirAddr (сервер) — Cloak
# аутентифицирует клиента по UID+PublicKey, а не по SNI.
#
# Использование:
#   bash cloak-rotate-client.sh                           # случайный домен
#   bash cloak-rotate-client.sh --set vk.com              # конкретный домен
#   bash cloak-rotate-client.sh --config /path/to/ck.json # другой конфиг
#   bash cloak-rotate-client.sh --list                    # список доменов
#
# Автозапуск (cron, каждые 4 часа):
#   0 */4 * * * /path/to/cloak-rotate-client.sh --config /path/to/ck-client.json
#
# Windows (Task Scheduler):
#   Действие: bash.exe
#   Аргументы: -c "/path/to/cloak-rotate-client.sh --config /path/to/ck-client.json"
#   Расписание: каждые 4 часа
# =============================================================================

set -euo pipefail

CK_CONFIG="${CK_CLIENT_CONFIG:-./ck-client.json}"
CK_CLIENT_PID=""
LOG_PREFIX="[cloak-rotate-client]"

# ── Список доменов (тот же что на сервере) ───────────────────────────────
DOMAINS=(
    "yandex.ru"
    "mail.ru"
    "vk.com"
    "ok.ru"
    "dzen.ru"
    "ya.ru"
    "avito.ru"
    "ozon.ru"
    "wildberries.ru"
    "sberbank.ru"
    "gosuslugi.ru"
    "mos.ru"
    "rutube.ru"
    "kinopoisk.ru"
    "hh.ru"
    "tinkoff.ru"
)

# ── Функции ──────────────────────────────────────────────────────────────
log()  { echo "$(date '+%Y-%m-%d %H:%M:%S') ${LOG_PREFIX} $*"; }
err()  { log "ERROR: $*" >&2; exit 1; }

get_current_domain() {
    if [[ ! -f "$CK_CONFIG" ]]; then
        err "Конфиг не найден: $CK_CONFIG"
    fi
    grep -oP '"ServerName"\s*:\s*"\K[^"]+' "$CK_CONFIG"
}

set_domain() {
    local new_domain="$1"
    local current
    current=$(get_current_domain)

    if [[ "$current" == "$new_domain" ]]; then
        log "Домен уже установлен: $new_domain (пропуск)"
        return 0
    fi

    # Атомарная замена
    local tmp
    tmp=$(mktemp "${CK_CONFIG}.XXXX")
    sed "s|\"ServerName\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"ServerName\": \"${new_domain}\"|" \
        "$CK_CONFIG" > "$tmp"
    mv "$tmp" "$CK_CONFIG"

    log "ServerName изменён: $current → $new_domain"

    # Перезапуск ck-client если запущен
    CK_CLIENT_PID=$(pgrep -f 'ck-client' 2>/dev/null || true)
    if [[ -n "$CK_CLIENT_PID" ]]; then
        log "Перезапускаю ck-client (PID: $CK_CLIENT_PID)..."
        # Посылаем SIGHUP для graceful перечитывания или убиваем/перезапускаем
        if systemctl is-active --quiet cloak-client 2>/dev/null; then
            systemctl restart cloak-client
            log "cloak-client сервис перезапущен"
        else
            kill "$CK_CLIENT_PID" 2>/dev/null || true
            log "ck-client остановлен. Запустите его заново вручную"
            log "Подсказка: ck-client -c $CK_CONFIG -s SERVER_IP -p 443 -l 127.0.0.1:1984 -u"
        fi
    else
        log "ck-client не запущен, только конфиг обновлён"
    fi
}

pick_random_domain() {
    local count=${#DOMAINS[@]}
    local current
    current=$(get_current_domain 2>/dev/null || echo "")

    local attempts=0
    local idx domain
    while true; do
        idx=$(( RANDOM % count ))
        domain="${DOMAINS[$idx]}"
        if [[ "$domain" != "$current" ]] || [[ $attempts -ge 10 ]]; then
            break
        fi
        attempts=$((attempts + 1))
    done
    echo "$domain"
}

# ── Парсинг аргументов ───────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config|-c) CK_CONFIG="$2"; shift 2 ;;
        --set)
            [[ -z "${2:-}" ]] && err "Укажите домен: --set domain.com"
            set_domain "$2"; exit 0 ;;
        --list)
            echo "Доступные домены (${#DOMAINS[@]}):"
            for d in "${DOMAINS[@]}"; do
                current=$(get_current_domain 2>/dev/null || echo "")
                if [[ "$d" == "$current" ]]; then
                    echo "  * $d (текущий)"
                else
                    echo "    $d"
                fi
            done
            exit 0 ;;
        --current)
            get_current_domain; exit 0 ;;
        --help|-h)
            sed -n '/^# Использование/,/^# ====/p' "$0" | grep -v "^# ====" | sed 's/^# \?//'
            exit 0 ;;
        *) err "Неизвестный параметр: $1" ;;
    esac
done

# Если дошли сюда — ротация
domain=$(pick_random_domain)
set_domain "$domain"
