#!/bin/bash
# =============================================================================
# remove-cloak.sh — Полное удаление Cloak с VPS1 и восстановление nginx
#
# Что делает:
#   1. Останавливает и удаляет cloak-server (сервис, бинарник, конфиги)
#   2. Удаляет cron-задачу ротации доменов
#   3. Восстанавливает nginx на порту 443 (reverse-proxy для админки)
#   4. Закрывает прямой доступ к 8443 (админка доступна через nginx на 443)
#   5. Сохраняет iptables
#
# Использование:
#   bash remove-cloak.sh [--vps1-ip IP] [--vps1-key KEY]
#
# Без аргументов — берёт из .env
# Идемпотентно: повторный запуск безопасен.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""

load_defaults_from_files

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-ip)   VPS1_IP="$2";   shift 2 ;;
        --vps1-user) VPS1_USER="$2"; shift 2 ;;
        --vps1-key)  VPS1_KEY="$2";  shift 2 ;;
        --vps1-pass) VPS1_PASS="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: bash $0 [--vps1-ip IP] [--vps1-key KEY]"
            exit 0 ;;
        *) err "Неизвестный параметр: $1" ;;
    esac
done

VPS1_KEY="$(expand_tilde "$VPS1_KEY")"
VPS1_KEY="$(auto_pick_key_if_missing "$VPS1_KEY")"

require_vars "remove-cloak.sh" VPS1_IP
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите --vps1-key или --vps1-pass (или VPS1_KEY в .env)"

run1() {
    local -a ssh_opts=(-T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=no)
    if [[ -n "$VPS1_KEY" ]]; then
        ssh "${ssh_opts[@]}" -i "$VPS1_KEY" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    else
        sshpass -p "$VPS1_PASS" ssh "${ssh_opts[@]}" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    fi
}

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║   Удаление Cloak и восстановление nginx                     ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Шаг 1: Удаление Cloak ──────────────────────────────────────────────
step "Шаг 1/4: Удаление Cloak сервера"

run1 "sudo bash -s" << 'REMOTE_SCRIPT'
set -euo pipefail

# Останавливаем и удаляем сервис
if systemctl is-active --quiet cloak-server 2>/dev/null; then
    systemctl stop cloak-server
    echo "cloak-server: stopped"
fi
if systemctl is-enabled --quiet cloak-server 2>/dev/null; then
    systemctl disable cloak-server
    echo "cloak-server: disabled"
fi
rm -f /etc/systemd/system/cloak-server.service

# Удаляем бинарник
rm -f /usr/local/bin/ck-server

# Удаляем конфиги и данные
rm -rf /etc/cloak

# Удаляем лог ротации
rm -f /var/log/cloak-rotate.log

# Удаляем cron-задачу ротации
if crontab -l 2>/dev/null | grep -q 'cloak-rotate-domain'; then
    ( crontab -l 2>/dev/null | grep -v 'cloak-rotate-domain' ) | crontab -
    echo "cloak-rotate cron: removed"
fi

systemctl daemon-reload
echo "CLOAK_REMOVED=true"
REMOTE_SCRIPT

ok "Cloak удалён (сервис, бинарник, конфиги, cron)"

# ── Шаг 2: Восстановление nginx ────────────────────────────────────────
step "Шаг 2/4: Восстановление nginx на порту 443"

run1 "sudo bash -s" << 'REMOTE_SCRIPT'
set -euo pipefail

# Проверяем что порт 443 свободен
if ss -tlnp | grep -q ':443 '; then
    BLOCKER=$(ss -tlnp | grep ':443 ' | grep -oP '"[^"]+"' | head -1)
    echo "WARN: порт 443 занят: $BLOCKER"
fi

# Включаем и запускаем nginx
nginx -t 2>&1
systemctl enable nginx
systemctl start nginx

if systemctl is-active --quiet nginx; then
    echo "NGINX_STATUS=active"
else
    echo "NGINX_STATUS=failed"
    journalctl -u nginx --no-pager -n 10
fi
REMOTE_SCRIPT

ok "nginx запущен на порту 443"

# ── Шаг 3: Firewall — закрываем прямой 8443, оставляем 80/443 ─────────
step "Шаг 3/4: Обновление firewall"

run1 "sudo bash -s" << 'REMOTE_SCRIPT'
set -euo pipefail

# Удаляем прямой доступ к 8443 (теперь админка за nginx на 443)
while iptables -C INPUT -p tcp --dport 8443 -j ACCEPT 2>/dev/null; do
    iptables -D INPUT -p tcp --dport 8443 -j ACCEPT
    echo "iptables: removed 8443 ACCEPT rule"
done

# Убеждаемся что 80 и 443 открыты
iptables -C INPUT -p tcp --dport 80 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 5 -p tcp --dport 80 -j ACCEPT
iptables -C INPUT -p tcp --dport 443 -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 5 -p tcp --dport 443 -j ACCEPT

# Сохраняем правила
if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save 2>/dev/null || true
fi

echo "FIREWALL_OK=true"
REMOTE_SCRIPT

ok "Firewall обновлён (443/80 открыты, 8443 закрыт)"

# ── Шаг 4: Верификация ─────────────────────────────────────────────────
step "Шаг 4/4: Проверка"

VERIFY=$(run1 "
echo '--- Services ---'
echo \"nginx: \$(systemctl is-active nginx)\"
echo \"vpn-admin: \$(systemctl is-active vpn-admin)\"
echo \"awg0: \$(systemctl is-active awg-quick@awg0)\"
echo \"awg1: \$(systemctl is-active awg-quick@awg1)\"
echo \"cloak-server: \$(systemctl is-active cloak-server 2>/dev/null || echo removed)\"
echo '--- Ports ---'
ss -tlnp 'sport = :443 or sport = :8443 or sport = :80'
echo '--- ip rule ---'
ip rule show
echo '--- table 200 ---'
ip route show table 200 2>/dev/null
echo '--- nginx health ---'
curl -kfsS https://127.0.0.1/api/health 2>&1 || echo 'HEALTH_FAILED'
echo '--- Firewall INPUT ---'
iptables -L INPUT -n --line-numbers 2>/dev/null | head -20
")

echo "$VERIFY"

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║          CLOAK УДАЛЁН, NGINX ВОССТАНОВЛЕН ✓                 ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Админка: ${BOLD}https://vpnrus.net${NC} (через nginx)"
echo -e "  VPN:     ${BOLD}подключение напрямую через AmneziaWG${NC}"
echo ""
