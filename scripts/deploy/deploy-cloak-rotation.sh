#!/usr/bin/env bash
# =============================================================================
# deploy-cloak-rotation.sh — установка авторотации доменов на работающий Cloak
#
# Безопасный скрипт: НЕ трогает ключи, НЕ перезаписывает ckserver.json,
# НЕ перезапускает ck-server. Только:
#   1. Загружает cloak-rotate-domain.sh на VPS1
#   2. Устанавливает cron (каждые 6 часов)
#   3. Копирует клиентский скрипт ротации в output
#
# Pre-check: убеждается что Cloak уже работает на VPS1.
#
# Использование:
#   bash deploy-cloak-rotation.sh [опции]
#
# Опции:
#   --vps1-ip        IP адрес VPS1
#   --vps1-user      Пользователь на VPS1 (default: root)
#   --vps1-key       Путь к SSH ключу для VPS1
#   --vps1-pass      Пароль для VPS1 (если нет ключа)
#   --interval       Интервал ротации в часах (default: 6)
#   --output-dir     Куда сохранить клиентский скрипт (default: ./vpn-output)
#   --rotate-now     Выполнить ротацию сразу после установки
#   --help           Справка
#
# Примеры:
#   # Базовый:
#   bash deploy-cloak-rotation.sh --vps1-ip 130.193.41.13 --vps1-key .ssh/ssh-key
#
#   # С немедленной ротацией и интервалом 4 часа:
#   bash deploy-cloak-rotation.sh --vps1-ip 130.193.41.13 --vps1-key .ssh/ssh-key \
#       --interval 4 --rotate-now
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# On Windows/Git Bash, convert drive-letter paths to /mnt/... style if needed
if [[ "$SCRIPT_DIR" =~ ^/[A-Za-z]/ ]]; then
    DRIVE=$(echo "$SCRIPT_DIR" | cut -c2 | tr '[:upper:]' '[:lower:]')
    REST=$(echo "$SCRIPT_DIR" | cut -c3-)
    SCRIPT_DIR="/mnt/${DRIVE}${REST}"
fi

source "${SCRIPT_DIR}/../../lib/common.sh"

SSH_BIN="${SSH_BIN:-ssh}"
SCP_BIN="${SCP_BIN:-scp}"
SSHPASS_BIN="${SSHPASS_BIN:-sshpass}"

# ── Параметры по умолчанию ─────────────────────────────────────────────────
VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""
INTERVAL_HOURS=6
OUTPUT_DIR="./vpn-output"
ROTATE_NOW=false

load_defaults_from_files

# ── Парсинг аргументов ─────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)       VPS1_IP="$2";       shift 2 ;;
        --vps1-user)     VPS1_USER="$2";     shift 2 ;;
        --vps1-key)      VPS1_KEY="$2";      shift 2 ;;
        --vps1-pass)     VPS1_PASS="$2";     shift 2 ;;
        --interval)      INTERVAL_HOURS="$2"; shift 2 ;;
        --output-dir)    OUTPUT_DIR="$2";    shift 2 ;;
        --rotate-now)    ROTATE_NOW=true;    shift ;;
        --help|-h)
            sed -n '/^# Использование/,/^# ====/p' "$0" | grep -v "^# ====" | sed 's/^# \?//'
            exit 0 ;;
        *) err "Неизвестный параметр: $1" ;;
    esac
done

# ── Фоллбэк ───────────────────────────────────────────────────────────────
VPS1_USER="${VPS1_USER:-root}"

# ── Подготовка SSH-ключей ──────────────────────────────────────────────────
VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"

# ── Проверка обязательных параметров ───────────────────────────────────────
require_vars "deploy-cloak-rotation.sh" VPS1_IP
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите --vps1-key или --vps1-pass (или VPS1_KEY в .env)"

# Ключи с /mnt/ (WSL/Windows) копируем во временные файлы
VPS1_KEY="$(prepare_key_for_ssh "$VPS1_KEY")"
trap cleanup_temp_keys EXIT

# ── SSH хелперы ────────────────────────────────────────────────────────────
run1() {
    local -a ssh_opts=(-T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=no)
    if [[ -n "$VPS1_KEY" ]]; then
        "$SSH_BIN" "${ssh_opts[@]}" -i "$VPS1_KEY" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    else
        "$SSHPASS_BIN" -p "$VPS1_PASS" "$SSH_BIN" "${ssh_opts[@]}" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    fi
}

upload1() { local f=$1; local dst=${2:-/tmp/$(basename $f)}
    local -a scp_opts=(-o StrictHostKeyChecking=accept-new)
    local src="$f"
    if [[ "$SCP_BIN" == *".exe" ]]; then
        src="$(_path_for_native_ssh "$f")"
    fi
    if [[ -n "$VPS1_KEY" ]]; then
        "$SCP_BIN" "${scp_opts[@]}" -i "$VPS1_KEY" "$src" "${VPS1_USER}@${VPS1_IP}:${dst}" 2>&1
    else
        "$SSHPASS_BIN" -p "$VPS1_PASS" "$SCP_BIN" "${scp_opts[@]}" "$src" "${VPS1_USER}@${VPS1_IP}:${dst}" 2>&1
    fi
}

# ── Проверка зависимостей ──────────────────────────────────────────────────
if [[ -n "$VPS1_PASS" ]]; then
    check_deps --need-sshpass
else
    check_deps
fi

# ── Начало ─────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Cloak — установка авторотации доменов                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
log "VPS1: ${BOLD}${VPS1_USER}@${VPS1_IP}${NC}"
log "Интервал: ${BOLD}каждые ${INTERVAL_HOURS}ч${NC}"
echo ""

mkdir -p "$OUTPUT_DIR"

# ── Шаг 1: Pre-check — Cloak уже работает ─────────────────────────────────
step "Шаг 1/3: Проверка что Cloak работает на VPS1"

PRECHECK=$(run1 "
# Проверяем что ck-server запущен
if systemctl is-active --quiet cloak-server 2>/dev/null; then
    echo 'CK_ACTIVE=true'
else
    echo 'CK_ACTIVE=false'
fi

# Проверяем что ckserver.json существует
if [[ -f /etc/cloak/ckserver.json ]]; then
    echo 'CK_CONFIG=true'
else
    echo 'CK_CONFIG=false'
fi

# Текущий домен
DOMAIN=\$(grep -oP '\"RedirAddr\"\\s*:\\s*\"\\K[^\"]+' /etc/cloak/ckserver.json 2>/dev/null || echo 'N/A')
echo \"CK_DOMAIN=\${DOMAIN}\"

# Текущие ключи на месте
if grep -q 'PrivateKey' /etc/cloak/ckserver.json 2>/dev/null; then
    echo 'CK_KEYS=true'
else
    echo 'CK_KEYS=false'
fi
") || err "Не удалось подключиться к VPS1 (${VPS1_IP})"

get_val() { echo "$PRECHECK" | grep "^${1}=" | cut -d= -f2-; }
CK_ACTIVE=$(get_val "CK_ACTIVE")
CK_CONFIG=$(get_val "CK_CONFIG")
CK_DOMAIN=$(get_val "CK_DOMAIN")
CK_KEYS=$(get_val "CK_KEYS")

[[ "$CK_CONFIG" != "true" ]] && err "ckserver.json не найден на VPS1. Сначала разверните Cloak: bash deploy-cloak.sh"
[[ "$CK_KEYS" != "true" ]]   && err "В ckserver.json нет PrivateKey. Cloak не настроен"
[[ "$CK_ACTIVE" != "true" ]] && warn "cloak-server не запущен (будет работать после запуска)"

ok "Cloak работает, текущий домен: ${BOLD}${CK_DOMAIN}${NC}"
log "Ключи и конфиг НЕ будут затронуты"

# ── Шаг 2: Установка скрипта и cron ───────────────────────────────────────
step "Шаг 2/3: Установка скрипта ротации"

ROTATE_SCRIPT="${SCRIPT_DIR}/cloak-rotate-domain.sh"
[[ ! -f "$ROTATE_SCRIPT" ]] && err "Скрипт ротации не найден: $ROTATE_SCRIPT"

log "Загружаю cloak-rotate-domain.sh на VPS1..."
upload1 "$ROTATE_SCRIPT" /tmp/cloak-rotate-domain.sh
run1 "sudo mv /tmp/cloak-rotate-domain.sh /etc/cloak/cloak-rotate-domain.sh && \
      sudo chmod +x /etc/cloak/cloak-rotate-domain.sh"
ok "Скрипт установлен: /etc/cloak/cloak-rotate-domain.sh"

# Устанавливаем cron (идемпотентно)
CRON_LINE="0 */${INTERVAL_HOURS} * * * /etc/cloak/cloak-rotate-domain.sh >> /var/log/cloak-rotate.log 2>&1"
run1 "( sudo crontab -l 2>/dev/null | grep -v 'cloak-rotate-domain'; echo '${CRON_LINE}' ) | sudo crontab -"
ok "Cron установлен: каждые ${INTERVAL_HOURS} часов"

# Немедленная ротация если запрошено
if [[ "$ROTATE_NOW" == "true" ]]; then
    log "Выполняю первую ротацию..."
    ROTATE_RESULT=$(run1 "sudo /etc/cloak/cloak-rotate-domain.sh" 2>&1) || warn "Ротация не удалась"
    echo "$ROTATE_RESULT" | tail -3
    NEW_DOMAIN=$(run1 "grep -oP '\"RedirAddr\"\\s*:\\s*\"\\K[^\"]+' /etc/cloak/ckserver.json 2>/dev/null || echo 'N/A'")
    ok "Новый домен: ${BOLD}${NEW_DOMAIN}${NC}"
fi

# ── Шаг 3: Копируем клиентский скрипт ────────────────────────────────────
step "Шаг 3/3: Клиентский скрипт ротации"

CLIENT_ROTATE="${SCRIPT_DIR}/cloak-rotate-client.sh"
if [[ -f "$CLIENT_ROTATE" ]]; then
    cp "$CLIENT_ROTATE" "${OUTPUT_DIR}/cloak-rotate-client.sh"
    chmod +x "${OUTPUT_DIR}/cloak-rotate-client.sh"
    ok "Скопирован: ${BOLD}${OUTPUT_DIR}/cloak-rotate-client.sh${NC}"
else
    warn "cloak-rotate-client.sh не найден"
fi

# ── Итог ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       АВТОРОТАЦИЯ ДОМЕНОВ УСТАНОВЛЕНА ✓                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${GREEN}Что сделано:${NC}"
echo -e "  - Скрипт ротации установлен на VPS1"
echo -e "  - Cron: каждые ${BOLD}${INTERVAL_HOURS}ч${NC} случайный домен из 16 популярных сайтов"
echo -e "  - Ключи и конфиг Cloak ${BOLD}не затронуты${NC}"
echo ""
echo -e "  ${GREEN}Управление на сервере:${NC}"
echo -e "  ${BOLD}/etc/cloak/cloak-rotate-domain.sh --current${NC}  — текущий домен"
echo -e "  ${BOLD}/etc/cloak/cloak-rotate-domain.sh --list${NC}     — список доменов"
echo -e "  ${BOLD}/etc/cloak/cloak-rotate-domain.sh --set vk.com${NC} — задать вручную"
echo -e "  ${BOLD}/etc/cloak/cloak-rotate-domain.sh${NC}            — ротация сейчас"
echo ""
echo -e "  ${GREEN}Лог ротации:${NC}"
echo -e "  ${BOLD}cat /var/log/cloak-rotate.log${NC}"
echo ""
echo -e "  ${GREEN}Клиентская ротация (опционально):${NC}"
echo -e "  ${BOLD}bash cloak-rotate-client.sh --config ck-client.json${NC}"
echo ""
