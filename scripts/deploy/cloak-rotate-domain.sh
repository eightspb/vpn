#!/usr/bin/env bash
# =============================================================================
# cloak-rotate-domain.sh — ротация маскировочного домена Cloak
#
# Устанавливается на VPS1 через cron. Каждый запуск:
#   1. Выбирает случайный домен из списка
#   2. Обновляет RedirAddr в ckserver.json
#   3. Перезапускает ck-server (graceful, <1с даунтайм)
#
# Клиентский ServerName не обязан совпадать с серверным RedirAddr —
# они работают независимо. Но для максимальной скрытности клиент тоже
# может ротировать (см. cloak-rotate-client.sh).
#
# RedirAddr — куда перенаправляются probe-запросы (активное зондирование).
# ServerName — SNI в TLS ClientHello (пассивный мониторинг провайдера).
#
# Использование:
#   bash cloak-rotate-domain.sh                    # ротация из списка
#   bash cloak-rotate-domain.sh --list             # показать список доменов
#   bash cloak-rotate-domain.sh --current          # текущий домен
#   bash cloak-rotate-domain.sh --set vk.com       # задать конкретный домен
#
# Cron (каждые 6 часов):
#   0 */6 * * * /etc/cloak/cloak-rotate-domain.sh >> /var/log/cloak-rotate.log 2>&1
# =============================================================================

set -euo pipefail

CK_CONFIG="/etc/cloak/ckserver.json"
CK_SERVICE="cloak-server"
LOG_PREFIX="[cloak-rotate]"

# ── Список доменов для ротации ───────────────────────────────────────────
# Популярные русскоязычные HTTPS-сайты. Провайдер видит SNI к этим доменам.
# Требования: сайт должен поддерживать TLS 1.3, быть популярным, не вызывать
# подозрений при подключении к московскому IP.
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
    grep -oP '"RedirAddr"\s*:\s*"\K[^"]+' "$CK_CONFIG"
}

set_domain() {
    local new_domain="$1"
    local current
    current=$(get_current_domain)

    if [[ "$current" == "$new_domain" ]]; then
        log "Домен уже установлен: $new_domain (пропуск)"
        return 0
    fi

    # Атомарная замена: записываем во временный файл, потом mv
    local tmp
    tmp=$(mktemp "${CK_CONFIG}.XXXX")
    sed "s|\"RedirAddr\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"RedirAddr\": \"${new_domain}\"|" \
        "$CK_CONFIG" > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$CK_CONFIG"

    log "Домен изменён: $current → $new_domain"

    # Перезапуск ck-server (graceful)
    if systemctl is-active --quiet "$CK_SERVICE"; then
        systemctl restart "$CK_SERVICE"
        sleep 1
        if systemctl is-active --quiet "$CK_SERVICE"; then
            log "ck-server перезапущен успешно"
        else
            # Откатываемся
            log "ОШИБКА: ck-server не запустился, откатываю на $current"
            sed -i "s|\"RedirAddr\"[[:space:]]*:[[:space:]]*\"[^\"]*\"|\"RedirAddr\": \"${current}\"|" \
                "$CK_CONFIG"
            systemctl restart "$CK_SERVICE"
            err "Откат выполнен на $current"
        fi
    else
        log "ВНИМАНИЕ: $CK_SERVICE не запущен, только конфиг обновлён"
    fi
}

pick_random_domain() {
    local count=${#DOMAINS[@]}
    local current
    current=$(get_current_domain 2>/dev/null || echo "")

    # Выбираем случайный домен, отличный от текущего
    local attempts=0
    local idx
    local domain
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
case "${1:-rotate}" in
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
        ;;
    --current)
        get_current_domain
        ;;
    --set)
        [[ -z "${2:-}" ]] && err "Укажите домен: --set domain.com"
        set_domain "$2"
        ;;
    rotate|"")
        domain=$(pick_random_domain)
        set_domain "$domain"
        ;;
    --help|-h)
        sed -n '/^# Использование/,/^# ====/p' "$0" | grep -v "^# ====" | sed 's/^# \?//'
        ;;
    *)
        err "Неизвестный параметр: $1. Используйте --help"
        ;;
esac
