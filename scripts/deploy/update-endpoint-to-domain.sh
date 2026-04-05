#!/bin/bash
# =============================================================================
# update-endpoint-to-domain.sh
#
# Заменяет IP-адрес VPS1 на доменное имя в клиентских конфигах vpn-output/
# и в шаблонах деплой-скриптов (deploy.sh, deploy-vps1.sh).
#
# Использование:
#   bash scripts/deploy/update-endpoint-to-domain.sh [--domain DOMAIN] [--vps1-ip IP] [--dry-run]
#
# Опции:
#   --domain    Домен для Endpoint (default: vpnrus.net)
#   --vps1-ip   IP VPS1 для замены (default: из .env)
#   --dry-run   Показать что изменится, не применять
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

DOMAIN="vpnrus.net"
VPS1_IP=""
DRY_RUN=false

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${BOLD}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; exit 1; }

# Аргументы
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)   DOMAIN="$2";   shift 2 ;;
        --vps1-ip)  VPS1_IP="$2";  shift 2 ;;
        --dry-run)  DRY_RUN=true;  shift ;;
        *) err "Неизвестный аргумент: $1" ;;
    esac
done

# Если IP не задан — берём из .env
if [[ -z "$VPS1_IP" ]]; then
    ENV_FILE="${REPO_ROOT}/.env"
    [[ -f "$ENV_FILE" ]] || err ".env не найден: ${ENV_FILE}"
    VPS1_IP=$(grep -E '^VPS1_IP=' "$ENV_FILE" | cut -d= -f2 | tr -d ' ')
    [[ -n "$VPS1_IP" ]] || err "VPS1_IP не найден в .env"
fi

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║     Замена Endpoint: IP → домен                              ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
log "Заменяем: ${BOLD}${VPS1_IP}${NC} → ${BOLD}${DOMAIN}${NC}"
$DRY_RUN && warn "Режим DRY-RUN — файлы не изменяются"
echo ""

CHANGED=0
SKIPPED=0

replace_in_file() {
    local file="$1"
    local old_endpoint="${VPS1_IP}:"
    local new_endpoint="${DOMAIN}:"

    if ! grep -q "$old_endpoint" "$file" 2>/dev/null; then
        return
    fi

    echo -e "  ${YELLOW}→${NC} ${file}"
    if ! $DRY_RUN; then
        # Бэкап
        cp "$file" "${file}.bak"
        # Замена IP на домен в Endpoint строках
        sed -i.tmp "s|Endpoint\s*=\s*${VPS1_IP}:|Endpoint            = ${DOMAIN}:|g" "$file"
        # Обновляем комментарий если есть
        sed -i.tmp "s|# VPS1 — точка входа (${VPS1_IP})|# VPS1 — точка входа (${DOMAIN})|g" "$file"
        rm -f "${file}.tmp"
    fi
    CHANGED=$((CHANGED + 1))
}

# ── 1. Клиентские конфиги в vpn-output/ ──────────────────────────────────────
log "Шаг 1/3: Клиентские конфиги (vpn-output/*.conf)"
OUTPUT_DIR="${REPO_ROOT}/vpn-output"

if [[ -d "$OUTPUT_DIR" ]]; then
    for conf in "${OUTPUT_DIR}"/*.conf; do
        [[ -f "$conf" ]] || continue
        replace_in_file "$conf"
    done
else
    warn "Директория vpn-output не найдена, пропускаем"
fi

# ── 2. deploy.sh ─────────────────────────────────────────────────────────────
log "Шаг 2/3: Шаблон в deploy.sh"
DEPLOY_SH="${REPO_ROOT}/scripts/deploy/deploy.sh"
if [[ -f "$DEPLOY_SH" ]]; then
    if grep -q 'Endpoint            = \${VPS1_IP}:' "$DEPLOY_SH"; then
        echo -e "  ${YELLOW}→${NC} ${DEPLOY_SH}"
        if ! $DRY_RUN; then
            cp "$DEPLOY_SH" "${DEPLOY_SH}.bak"
            sed -i.tmp 's|Endpoint            = \${VPS1_IP}:\${VPS1_PORT_CLIENTS}|Endpoint            = '"${DOMAIN}"':\${VPS1_PORT_CLIENTS}|g' "$DEPLOY_SH"
            sed -i.tmp 's|# VPS1 — точка входа (\${VPS1_IP})|# VPS1 — точка входа ('"${DOMAIN}"')|g' "$DEPLOY_SH"
            rm -f "${DEPLOY_SH}.tmp"
        fi
        CHANGED=$((CHANGED + 1))
    else
        ok "deploy.sh — уже использует домен или не требует изменений"
        SKIPPED=$((SKIPPED + 1))
    fi
fi

# ── 3. deploy-vps1.sh ────────────────────────────────────────────────────────
log "Шаг 3/3: Шаблон в deploy-vps1.sh"
DEPLOY_VPS1="${REPO_ROOT}/scripts/deploy/deploy-vps1.sh"
if [[ -f "$DEPLOY_VPS1" ]]; then
    if grep -q 'Endpoint            = \${VPS1_IP}:' "$DEPLOY_VPS1"; then
        echo -e "  ${YELLOW}→${NC} ${DEPLOY_VPS1}"
        if ! $DRY_RUN; then
            cp "$DEPLOY_VPS1" "${DEPLOY_VPS1}.bak"
            sed -i.tmp 's|Endpoint            = \${VPS1_IP}:\${VPS1_PORT_CLIENTS}|Endpoint            = '"${DOMAIN}"':\${VPS1_PORT_CLIENTS}|g' "$DEPLOY_VPS1"
            rm -f "${DEPLOY_VPS1}.tmp"
        fi
        CHANGED=$((CHANGED + 1))
    else
        ok "deploy-vps1.sh — уже использует домен или не требует изменений"
        SKIPPED=$((SKIPPED + 1))
    fi
fi

# ── Итог ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}══════════════════ Итог ══════════════════${NC}"
if $DRY_RUN; then
    log "DRY-RUN: изменений внесено 0, обнаружено файлов для изменения: ${CHANGED}"
else
    ok "Изменено файлов: ${BOLD}${CHANGED}${NC}"
    [[ $SKIPPED -gt 0 ]] && log "Пропущено (уже актуально): ${SKIPPED}"
    echo ""
    log "Бэкапы сохранены с расширением .bak рядом с файлами"
    echo ""
    echo -e "${GREEN}Готово.${NC} Теперь:"
    echo -e "  1. Проверь конфиги: ${BOLD}grep Endpoint vpn-output/*.conf${NC}"
    echo -e "  2. Раздай обновлённые .conf пользователям"
    echo -e "  3. Убедись что DNS ${BOLD}${DOMAIN}${NC} указывает на ${BOLD}${VPS1_IP}${NC}"
fi
echo ""
