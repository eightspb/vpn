#!/usr/bin/env bash
# =============================================================================
# manage.sh — единая точка входа для управления VPN-инфраструктурой
#
# Использование:
#   bash manage.sh <команда> [опции]
#
# Команды:
#   deploy      Деплой VPN (полный или по частям)
#   monitor     Мониторинг серверов (реалтайм или веб-дашборд)
#   admin       Админ-панель (start/stop/status/setup/restart/logs)
#   add-peer    Добавить новый WireGuard-пир на VPS1
#   peers       Управление пирами (add/batch/list/remove/export/info)
#   check       Проверить связность VPN-цепочки
#   help        Показать эту справку
#
# Примеры:
#   bash manage.sh deploy --vps1-ip 1.2.3.4 --vps1-key .ssh/id_rsa \
#                         --vps2-ip 5.6.7.8 --vps2-key .ssh/id_rsa
#   bash manage.sh deploy --vps1 --vps1-ip 1.2.3.4 --vps1-key .ssh/id_rsa --vps2-ip 5.6.7.8
#   bash manage.sh deploy --vps2 --vps2-ip 5.6.7.8 --vps2-key .ssh/id_rsa
#   bash manage.sh deploy --proxy --vps2-ip 5.6.7.8 --vps2-key .ssh/id_rsa
#   bash manage.sh monitor
#   bash manage.sh monitor --web
#   bash manage.sh add-peer
#   bash manage.sh add-peer --peer-name tablet --peer-ip 10.9.0.5
#   bash manage.sh peers add --name laptop --type pc --qr
#   bash manage.sh peers batch --prefix user --count 50
#   bash manage.sh peers list
#   bash manage.sh check
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
manage.sh — управление VPN-инфраструктурой (AmneziaWG + YouTube Proxy)

Использование:
  bash manage.sh <команда> [опции]

Команды:
  deploy      Деплой VPN (полный или по частям)
  monitor     Мониторинг серверов
  admin       Админ-панель (start/stop/status/setup/restart/logs)
  add-peer    Добавить новый WireGuard-пир (legacy)
  peers       Управление пирами (add/batch/list/remove/export/info)
  check       Проверить связность VPN-цепочки
  help        Показать эту справку

Запустите "bash manage.sh <команда> --help" для подробной справки по команде.
EOF
}

usage_deploy() {
    cat <<'EOF'
manage.sh deploy — деплой VPN

Режимы (по умолчанию — полный деплой обоих серверов):
  (без флага)   Полный деплой: VPS1 + VPS2 (через deploy.sh)
  --vps1        Только VPS1 (через deploy-vps1.sh)
  --vps2        Только VPS2 (через deploy-vps2.sh, требует --keys-file)
  --proxy       Только YouTube Ad Proxy на VPS2 (через deploy-proxy.sh)

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
  --adguard-pass PASS   Пароль AdGuard Home (default: admin123)
  --output-dir DIR      Куда сохранить конфиги (default: ./vpn-output)
  --with-proxy          Задеплоить YouTube Proxy на VPS2
  --remove-adguard      Удалить AdGuard Home (только с --with-proxy)

Для --vps1: те же опции без vps2-* (кроме --vps2-ip для туннеля)
Для --vps2: --vps2-ip, --vps2-key/--vps2-pass, --keys-file
Для --proxy: --vps2-ip, --vps2-key, [--remove-adguard]

Примеры:
  bash manage.sh deploy \
    --vps1-ip 130.193.41.13 --vps1-user slava --vps1-key .ssh/ssh-key-1772056840349 \
    --vps2-ip 38.135.122.81 --vps2-key .ssh/ssh-key-1772056840349 \
    --with-proxy --remove-adguard

  bash manage.sh deploy --vps1 \
    --vps1-ip 130.193.41.13 --vps1-user slava --vps1-key .ssh/ssh-key-1772056840349 --vps2-ip 38.135.122.81

  bash manage.sh deploy --proxy \
    --vps2-ip 38.135.122.81 --vps2-key .ssh/id_rsa --remove-adguard
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
  bash manage.sh add-peer --vps1-ip 130.193.41.13 --vps1-user slava --vps1-key .ssh/ssh-key-1772056840349
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
  bash manage.sh check --vps1-ip 130.193.41.13 --vps1-user slava --vps1-key .ssh/ssh-key-1772056840349
EOF
}

# ── Подкоманда: deploy ────────────────────────────────────────────────────────

cmd_deploy() {
    local mode="full"
    local extra_args=()

    # Разбираем первый аргумент — режим
    if [[ "${1:-}" == "--vps1" ]]; then
        mode="vps1"; shift
    elif [[ "${1:-}" == "--vps2" ]]; then
        mode="vps2"; shift
    elif [[ "${1:-}" == "--proxy" ]]; then
        mode="proxy"; shift
    fi

    if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
        usage_deploy; return 0
    fi

    extra_args=("$@")

    case "$mode" in
        full)
            log "Запуск полного деплоя (deploy.sh)..."
            bash "${SCRIPT_DIR}/scripts/deploy/deploy.sh" "${extra_args[@]+"${extra_args[@]}"}"
            ;;
        vps1)
            log "Запуск деплоя VPS1 (deploy-vps1.sh)..."
            bash "${SCRIPT_DIR}/scripts/deploy/deploy-vps1.sh" "${extra_args[@]+"${extra_args[@]}"}"
            ;;
        vps2)
            log "Запуск деплоя VPS2 (deploy-vps2.sh)..."
            bash "${SCRIPT_DIR}/scripts/deploy/deploy-vps2.sh" "${extra_args[@]+"${extra_args[@]}"}"
            ;;
        proxy)
            log "Запуск деплоя YouTube Proxy (deploy-proxy.sh)..."
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
  start        Запуск (dev: 127.0.0.1:8081, в WSL: 0.0.0.0:8081)
  start-prod   Запуск HTTPS (0.0.0.0:8443)
  stop         Остановка
  status       Проверка статуса
  setup        Установка зависимостей
  restart      Перезапуск
  logs         Просмотр логов
  reset-password  Сбросить пароль admin на «admin» (если забыли)

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
    help|--help|-h) usage_main ;;
    *)
        echo -e "${RED}Неизвестная команда: ${COMMAND}${NC}" >&2
        echo "" >&2
        usage_main >&2
        exit 1
        ;;
esac
