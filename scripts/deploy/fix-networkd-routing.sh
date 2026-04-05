#!/bin/bash
# =============================================================================
# fix-networkd-routing.sh — Устойчивость ip rule к перезапуску systemd-networkd
#
# Проблема: systemd-networkd при перезапуске (DHCP renewal, обновление)
# сбрасывает все ip rule. Правило "from 10.9.0.0/24 table 200" пропадает,
# клиентский VPN-трафик перестаёт маршрутизироваться через awg0 → VPS2.
#
# Решение: systemd drop-in для networkd, который восстанавливает ip rule
# после каждого перезапуска networkd.
#
# Использование:
#   bash fix-networkd-routing.sh [--vps1-ip IP] [--vps1-key KEY]
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

require_vars "fix-networkd-routing.sh" VPS1_IP
[[ -z "$VPS1_KEY" && -z "$VPS1_PASS" ]] && err "Укажите --vps1-key или --vps1-pass (или VPS1_KEY в .env)"

run1() {
    local -a ssh_opts=(-T -o StrictHostKeyChecking=accept-new -o ConnectTimeout=15 -o BatchMode=no)
    if [[ -n "$VPS1_KEY" ]]; then
        ssh "${ssh_opts[@]}" -i "$VPS1_KEY" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    else
        sshpass -p "$VPS1_PASS" ssh "${ssh_opts[@]}" "${VPS1_USER}@${VPS1_IP}" "$@" 2>&1
    fi
}

step "Установка systemd drop-in для восстановления ip rule после рестарта networkd"

run1 "sudo bash -s" << 'REMOTE_SCRIPT'
set -euo pipefail

# ── Создаём drop-in для systemd-networkd ────────────────────────────────
mkdir -p /etc/systemd/system/systemd-networkd.service.d

cat > /etc/systemd/system/systemd-networkd.service.d/restore-vpn-routing.conf << 'DROPEOF'
[Service]
ExecStartPost=/bin/bash -c '\
  sleep 2; \
  if ip link show awg1 >/dev/null 2>&1 && ip link show awg0 >/dev/null 2>&1; then \
    ip rule show | grep -q "from 10.9.0.0/24 lookup 200" || ip rule add from 10.9.0.0/24 table 200; \
    ip route show table 200 2>/dev/null | grep -q "default via 10.8.0.2 dev awg0" || ip route add default via 10.8.0.2 dev awg0 table 200 2>/dev/null || true; \
    echo "[vpn-routing] ip rule restored after networkd restart"; \
  fi'
DROPEOF
chmod 644 /etc/systemd/system/systemd-networkd.service.d/restore-vpn-routing.conf

systemctl daemon-reload

# ── Проверяем текущее состояние ─────────────────────────────────────────
echo "--- Verification ---"
ip rule show | grep -q 'from 10.9.0.0/24 lookup 200' && echo 'ip rule: OK' || echo 'ip rule: MISSING'
ip route show table 200 2>/dev/null | grep -q 'default via 10.8.0.2 dev awg0' && echo 'table 200: OK' || echo 'table 200: MISSING'
echo 'DROP-IN INSTALLED OK'
REMOTE_SCRIPT

ok "Drop-in установлен. ip rule будет автоматически восстанавливаться после рестарта networkd."
