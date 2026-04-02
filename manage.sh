#!/usr/bin/env bash
# =============================================================================
# manage.sh — единая точка входа для управления VPN-инфраструктурой
#
# Использование:
#   bash manage.sh <команда> [опции]
#
# Команды:
#   deploy      Деплой (--admin для админки, без флага — полный VPN)
#   monitor     Мониторинг серверов (реалтайм / --web)
#   admin       Локальная админ-панель (start/stop/status/setup/restart/logs)
#   peers       Управление пирами (add/batch/list/remove/export/info)
#   check       Проверить связность VPN-цепочки
#   audit       Аудит безопасности и эффективности (read-only)
#   help        Показать эту справку
#
# Примеры:
#   bash manage.sh deploy --admin                    # обновить админку
#   bash manage.sh deploy                            # полный деплой VPN
#   bash manage.sh admin start                       # запустить локально
#   bash manage.sh peers list                        # список пиров
#   bash manage.sh monitor --web                     # веб-мониторинг
#   bash manage.sh check                             # проверить связность
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Конвертируем Windows-путь в /mnt/... если нужно
if [[ "$SCRIPT_DIR" =~ ^/[A-Za-z]/ ]]; then
    _drive=$(echo "$SCRIPT_DIR" | cut -c2 | tr '[:upper:]' '[:lower:]')
    _rest=$(echo "$SCRIPT_DIR" | cut -c3-)
    SCRIPT_DIR="/mnt/${_drive}${_rest}"
fi

source "${SCRIPT_DIR}/lib/common.sh"

# ── Справка ───────────────────────────────────────────────────────────────────

usage_main() {
    cat <<'EOF'
manage.sh — управление VPN-инфраструктурой (AmneziaWG)

Использование:
  bash manage.sh <команда> [опции]

Команды:
  deploy      Деплой (--admin для админки, без флага — полный VPN)
  monitor     Мониторинг серверов (реалтайм / --web)
  admin       Локальная админ-панель (start/stop/status/setup/restart/logs)
  peers       Управление пирами (add/batch/list/remove/export/info)
  check       Проверить связность VPN-цепочки
  audit       Аудит безопасности и эффективности (read-only)
  help        Показать эту справку

Частые сценарии:
  bash manage.sh deploy --admin          # обновить админку (VPN не трогает)
  bash manage.sh deploy                  # полный деплой VPN с нуля
  bash manage.sh admin start             # запустить админку локально
  bash manage.sh peers list              # список пиров

Запустите "bash manage.sh <команда> --help" для подробной справки.
EOF
}

usage_deploy() {
    cat <<'EOF'
manage.sh deploy — деплой компонентов VPN-инфраструктуры

Режимы:
  --admin       ★ Только админ-панель + бот на VPS1 (БЕЗ изменения VPN)
                  Обновляет код, перезапускает admin-server и vpn-bot.
                  Безопасно: VPN-тоннели и конфиги не затрагиваются.

  (без флага)   Полный деплой: VPS1 + VPS2 (VPN + всё остальное)
  --vps1        Только VPS1 (VPN-конфиги + AmneziaWG)
  --vps2        Только VPS2 (требует --keys-file от deploy-vps1)
  --proxy       YouTube Ad Proxy на VPS2 (⚠ проект неактивен)

Опции для --admin:
  --vps1-ip IP          IP VPS1 (или из .env)
  --vps1-user USER      SSH-пользователь VPS1 (default: из .env)
  --vps1-key PATH       SSH-ключ VPS1 (или из .env)
  --admin-password PASS Установить пароль admin (опционально)

Опции для полного деплоя:
  --vps1-ip IP          IP VPS1
  --vps1-user USER      SSH-пользователь VPS1 (default: root)
  --vps1-key PATH       SSH-ключ VPS1
  --vps1-pass PASS      SSH-пароль VPS1
  --vps2-ip IP          IP VPS2
  --vps2-user USER      SSH-пользователь VPS2 (default: root)
  --vps2-key PATH       SSH-ключ VPS2
  --vps2-pass PASS      SSH-пароль VPS2
  --client-ip IP        IP клиента в VPN (default: 10.9.0.2)
  --adguard-pass PASS   Пароль AdGuard Home
  --output-dir DIR      Куда сохранить конфиги (default: ./vpn-output)
  --with-proxy          Задеплоить YouTube Proxy на VPS2 (⚠ неактивен)
  --remove-adguard      Удалить AdGuard Home (только с --with-proxy)
  --regen-configs       Пересобрать клиентские конфиги после деплоя

Примеры:
  # ★ Обновить только админку (самый частый случай):
  bash manage.sh deploy --admin

  # Полный деплой VPN с нуля:
  bash manage.sh deploy \
    --vps1-ip 89.169.172.51 --vps1-user slava --vps1-key .ssh/key \
    --vps2-ip 38.135.122.81 --vps2-key .ssh/key \
    --adguard-pass "Strong-Password-123"

  # Только VPS1 (первый этап двухфазного деплоя):
  bash manage.sh deploy --vps1 \
    --vps1-ip 89.169.172.51 --vps1-key .ssh/key --vps2-ip 38.135.122.81
EOF
}

usage_monitor() {
    cat <<'EOF'
manage.sh monitor — мониторинг серверов

Режимы:
  (без флага)   Реалтайм-монитор в терминале (monitor-realtime.sh)
  --web         Веб-дашборд на http://localhost:8080 (monitor-web.sh)

Опции:
  --vps1-ip IP        IP VPS1 (или из .env)
  --vps1-user USER    SSH-пользователь VPS1
  --vps1-key PATH     SSH-ключ VPS1
  --vps1-pass PASS    SSH-пароль VPS1
  --vps2-ip IP        IP VPS2 (или из .env)
  --vps2-user USER    SSH-пользователь VPS2
  --vps2-key PATH     SSH-ключ VPS2
  --vps2-pass PASS    SSH-пароль VPS2
  --interval SEC      Интервал обновления (default: 1 для realtime, 5 для web)

Примеры:
  bash manage.sh monitor
  bash manage.sh monitor --web
  bash manage.sh monitor --vps1-ip 1.2.3.4 --vps1-key .ssh/id_rsa \
                         --vps2-ip 5.6.7.8 --vps2-key .ssh/id_rsa
EOF
}

usage_add_peer() {
    cat <<'EOF'
manage.sh add-peer — добавить новый WireGuard-пир на VPS1

Опции:
  --vps1-ip IP        IP VPS1 (или из .env)
  --vps1-user USER    SSH-пользователь VPS1 (default: root)
  --vps1-key PATH     SSH-ключ VPS1
  --vps1-pass PASS    SSH-пароль VPS1
  --peer-ip IP        IP нового пира (default: автоопределение)
  --peer-name NAME    Имя пира (default: phone)
  --tun-net NET       Сеть без последнего октета (default: 10.9.0)
  --output-dir DIR    Куда сохранить конфиг (default: ./vpn-output)

Примеры:
  bash manage.sh add-peer
  bash manage.sh add-peer --peer-name tablet --peer-ip 10.9.0.5
  bash manage.sh add-peer --vps1-ip 89.169.172.51 --vps1-user slava --vps1-key .ssh/ssh-key-1772056840349
EOF
}

usage_check() {
    cat <<'EOF'
manage.sh check — проверить связность VPN-цепочки

Запускает check_ping.sh на VPS1 через SSH.

Опции:
  --vps1-ip IP        IP VPS1 (или из .env)
  --vps1-user USER    SSH-пользователь VPS1 (default: root)
  --vps1-key PATH     SSH-ключ VPS1
  --vps1-pass PASS    SSH-пароль VPS1
  --script-path PATH  Путь к check_ping.sh на сервере (default: /tmp/check_ping.sh)

Примеры:
  bash manage.sh check
  bash manage.sh check --vps1-ip 89.169.172.51 --vps1-user slava --vps1-key .ssh/ssh-key-1772056840349
EOF
}

usage_audit() {
    cat <<'EOF'
manage.sh audit — аудит безопасности и эффективности (read-only)

Опции:
  --strict        завершиться с ошибкой при critical/high
  --with-servers  добавить read-only проверки VPS по SSH
  --output FILE   сохранить отчёт в файл

Примеры:
  bash manage.sh audit
  bash manage.sh audit --strict
  bash manage.sh audit --with-servers --output ./vpn-output/audit-report.txt
EOF
}

# ── Подкоманда: deploy ────────────────────────────────────────────────────────

cmd_deploy() {
    local mode="full"
    local extra_args=()
    local regen_configs=false

    # Разбираем первый аргумент — режим
    if [[ "${1:-}" == "--admin" ]]; then
        mode="admin"; shift
    elif [[ "${1:-}" == "--vps1" ]]; then
        mode="vps1"; shift
    elif [[ "${1:-}" == "--vps2" ]]; then
        mode="vps2"; shift
    elif [[ "${1:-}" == "--proxy" ]]; then
        mode="proxy"; shift
    fi

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage_deploy; return 0
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --regen-configs)
                regen_configs=true
                shift
                ;;
            *)
                extra_args+=("$1")
                shift
                ;;
        esac
    done

    case "$mode" in
        admin)
            [[ "$regen_configs" == "true" ]] && err "--regen-configs недоступен для --admin"
            log "Деплой админ-панели + бота на VPS1 (VPN не затрагивается)..."
            bash "${SCRIPT_DIR}/scripts/deploy/redeploy-admin-vps1.sh" "${extra_args[@]+"${extra_args[@]}"}"
            ;;
        full)
            log "Запуск полного деплоя (deploy.sh)..."
            bash "${SCRIPT_DIR}/scripts/deploy/deploy.sh" "${extra_args[@]+"${extra_args[@]}"}"
            if [[ "$regen_configs" == "true" ]]; then
                local regen_script="${SCRIPT_DIR}/scripts/tools/generate-all-configs.sh"
                [[ -f "$regen_script" ]] || err "Не найден скрипт перегенерации конфигов: $regen_script"
                log "Перегенерация клиентских конфигов (generate-all-configs.sh)..."
                bash "$regen_script"
                [[ -f "${SCRIPT_DIR}/vpn-output/client.conf" ]] || err "Перегенерация не завершена: отсутствует vpn-output/client.conf"
                [[ -f "${SCRIPT_DIR}/vpn-output/phone.conf" ]] || err "Перегенерация не завершена: отсутствует vpn-output/phone.conf"
                ok "Клиентские конфиги пересобраны: vpn-output/client.conf, vpn-output/phone.conf"
            fi
            ;;
        vps1)
            [[ "$regen_configs" == "true" ]] && err "--regen-configs доступен только для полного деплоя"
            log "Запуск деплоя VPS1 (deploy-vps1.sh)..."
            bash "${SCRIPT_DIR}/scripts/deploy/deploy-vps1.sh" "${extra_args[@]+"${extra_args[@]}"}"
            ;;
        vps2)
            [[ "$regen_configs" == "true" ]] && err "--regen-configs доступен только для полного деплоя"
            log "Запуск деплоя VPS2 (deploy-vps2.sh)..."
            bash "${SCRIPT_DIR}/scripts/deploy/deploy-vps2.sh" "${extra_args[@]+"${extra_args[@]}"}"
            ;;
        proxy)
            [[ "$regen_configs" == "true" ]] && err "--regen-configs доступен только для полного деплоя"
            log "Запуск деплоя YouTube Proxy (deploy-proxy.sh)..."
            warn "⚠ YouTube Proxy — неактивный проект. Убедитесь, что это нужно."
            bash "${SCRIPT_DIR}/scripts/deploy/deploy-proxy.sh" "${extra_args[@]+"${extra_args[@]}"}"
            ;;
    esac
}

# ── Подкоманда: monitor ───────────────────────────────────────────────────────

cmd_monitor() {
    local mode="realtime"
    local extra_args=()

    if [[ "${1:-}" == "--web" ]]; then
        mode="web"; shift
    fi

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage_monitor; return 0
    fi

    extra_args=("$@")

    case "$mode" in
        realtime)
            log "Запуск реалтайм-монитора (monitor-realtime.sh)..."
            bash "${SCRIPT_DIR}/scripts/monitor/monitor-realtime.sh" "${extra_args[@]+"${extra_args[@]}"}"
            ;;
        web)
            log "Запуск веб-дашборда (monitor-web.sh)..."
            log "Откройте: http://localhost:8080/dashboard.html"
            bash "${SCRIPT_DIR}/scripts/monitor/monitor-web.sh" "${extra_args[@]+"${extra_args[@]}"}"
            ;;
    esac
}

# ── Подкоманда: admin ─────────────────────────────────────────────────────────

usage_admin() {
    cat <<'EOF'
manage.sh admin — управление VPN Admin Panel

Команды:
  start        Запуск (dev: 127.0.0.1:8081; для внешнего доступа используйте --host 0.0.0.0)
  start-prod   Запуск HTTPS (0.0.0.0:8443)
  stop         Остановка
  status       Проверка статуса
  setup        Подготовка uv-окружения и установка зависимостей
  restart      Перезапуск
  logs         Просмотр логов
  reset-password  Сбросить пароль admin на «My-secure-admin-password» (если забыли)

Опции:
  --port PORT  Порт (по умолчанию: 8081 dev, 8443 prod)
  --host HOST  Host для bind (по умолчанию: auto)
  --cert FILE  SSL-сертификат (для start-prod)
  --key FILE   SSL-ключ (для start-prod)

Примеры:
  bash manage.sh admin setup
  bash manage.sh admin start
  bash manage.sh admin start --host 0.0.0.0
  bash manage.sh admin start --port 9000
  bash manage.sh admin start-prod --cert cert.pem --key key.pem
  bash manage.sh admin status
  bash manage.sh admin stop
  bash manage.sh admin logs
  bash manage.sh admin reset-password   # если забыли пароль
EOF
}

cmd_admin() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage_admin; return 0
    fi

    local subcmd="${1:-start}"
    shift || true

    log "Запуск админ-панели (deploy-admin.sh ${subcmd})..."
    bash "${SCRIPT_DIR}/scripts/deploy/deploy-admin.sh" "$subcmd" "$@"
}

# ── Подкоманда: add-peer ──────────────────────────────────────────────────────

cmd_add_peer() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage_add_peer; return 0
    fi

    log "Запуск добавления пира (add_phone_peer.sh)..."
    bash "${SCRIPT_DIR}/scripts/tools/add_phone_peer.sh" "$@"
}

# ── Подкоманда: check ─────────────────────────────────────────────────────────

cmd_check() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage_check; return 0
    fi

    local VPS1_IP="" VPS1_USER="" VPS1_KEY="" VPS1_PASS=""
    local SCRIPT_REMOTE_PATH="/tmp/check_ping.sh"

    load_defaults_from_files

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vps1-ip)      VPS1_IP="$2";              shift 2 ;;
            --vps1-user)    VPS1_USER="$2";            shift 2 ;;
            --vps1-key)     VPS1_KEY="$2";             shift 2 ;;
            --vps1-pass)    VPS1_PASS="$2";            shift 2 ;;
            --script-path)  SCRIPT_REMOTE_PATH="$2";   shift 2 ;;
            *) err "Неизвестный параметр: $1" ;;
        esac
    done

    VPS1_USER="${VPS1_USER:-root}"

    [[ -z "$VPS1_IP" ]] && err "Укажите VPS1_IP в .env или --vps1-ip"
    [[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите --vps1-key или --vps1-pass"

    VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
    VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"
    VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"
    trap cleanup_temp_keys EXIT

    local check_script="${SCRIPT_DIR}/scripts/tools/check_ping.sh"
    [[ -f "$check_script" ]] || err "Не найден скрипт: $check_script"

    log "Загружаю check_ping.sh на VPS1 (${VPS1_IP})..."
    ssh_upload "$check_script" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "$SCRIPT_REMOTE_PATH"

    log "Запускаю проверку связности на VPS1..."
    ssh_exec "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS" "sudo bash $SCRIPT_REMOTE_PATH"
}

# ── Подкоманда: audit ─────────────────────────────────────────────────────────

cmd_audit() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage_audit; return 0
    fi
    log "Запуск аудита безопасности/эффективности (audit-security-efficiency.sh)..."
    bash "${SCRIPT_DIR}/scripts/tools/audit-security-efficiency.sh" "$@"
}

# ── Подкоманда: peers ─────────────────────────────────────────────────────────

cmd_peers() {
    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        bash "${SCRIPT_DIR}/scripts/tools/manage-peers.sh" help
        return 0
    fi

    log "Запуск управления пирами (manage-peers.sh)..."
    bash "${SCRIPT_DIR}/scripts/tools/manage-peers.sh" "$@"
}

# ── Диспетчер команд ──────────────────────────────────────────────────────────

COMMAND="${1:-help}"
shift || true

case "$COMMAND" in
    deploy)     cmd_deploy   "$@" ;;
    monitor)    cmd_monitor  "$@" ;;
    admin)      cmd_admin    "$@" ;;
    add-peer)   cmd_add_peer "$@" ;;
    peers)      cmd_peers    "$@" ;;
    check)      cmd_check    "$@" ;;
    audit)      cmd_audit    "$@" ;;
    help|--help|-h) usage_main ;;
    *)
        echo -e "${RED}Неизвестная команда: ${COMMAND}${NC}" >&2
        echo "" >&2
        usage_main >&2
        exit 1
        ;;
esac
