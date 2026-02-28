#!/usr/bin/env bash
# =============================================================================
# benchmark.sh — замер производительности VPN-серверов
#
# Собирает: ping, скорость загрузки, MTU, handshake-возраст, sysctl,
#           задержку туннеля VPS1→VPS2.
#
# Использование:
#   bash benchmark.sh [--vps1-only] [--vps2-only] [--help]
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/../../lib/common.sh"

# ── Параметры по умолчанию ────────────────────────────────────────────────────
VPS1_IP=""; VPS1_USER=""; VPS1_KEY=""; VPS1_PASS=""
VPS2_IP=""; VPS2_USER=""; VPS2_KEY=""; VPS2_PASS=""

VPS1_ONLY=false
VPS2_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --vps1-only) VPS1_ONLY=true ;;
        --vps2-only) VPS2_ONLY=true ;;
        --help|-h)
            sed -n '2,9p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) warn "Неизвестный аргумент: $1" ;;
    esac
    shift
done

load_defaults_from_files

VPS1_USER="${VPS1_USER:-root}"
VPS2_USER="${VPS2_USER:-root}"

[[ -z "${VPS1_IP}" ]] && err "VPS1_IP не задан. Проверьте .env"

VPS1_KEY="$(expand_tilde "${VPS1_KEY}")"
VPS2_KEY="$(expand_tilde "${VPS2_KEY:-}")"
VPS1_KEY="$(prepare_key_for_ssh "${VPS1_KEY}")"
VPS2_KEY="$(prepare_key_for_ssh "${VPS2_KEY:-}")"
trap cleanup_temp_keys EXIT

check_deps

DO_VPS1=true
DO_VPS2=true
[[ "${VPS1_ONLY}" == "true" ]] && DO_VPS2=false
[[ "${VPS2_ONLY}" == "true" ]] && DO_VPS1=false
[[ -z "${VPS2_IP:-}" ]] && { warn "VPS2_IP не задан — пропускаем VPS2"; DO_VPS2=false; }

# ── Функция полного замера одного сервера ─────────────────────────────────────
benchmark_server() {
    local label="$1" ip="$2" user="$3" key="$4" pass="$5"

    log "Замер ${label} (${ip})..."

    local ping_raw ping_summary speed_raw speed_mb
    local mtu_awg0 mtu_awg1 handshakes
    local rmem wmem congestion backlog fastopen slow_start mtu_probe

    ping_raw="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "ping -c 10 -q 8.8.8.8 2>&1 | tail -3" 35 2>/dev/null || echo 'N/A')"

    ping_summary="$(echo "$ping_raw" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' | head -1 || echo 'N/A')"

    speed_raw="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "curl -o /dev/null -w '%{speed_download}' --max-time 15 'https://speed.cloudflare.com/__down?bytes=50000000' 2>/dev/null || echo 0" 25 2>/dev/null || echo '0')"
    speed_mb="$(awk "BEGIN{printf \"%.2f\", ${speed_raw:-0}/1048576}")"

    mtu_awg0="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "ip link show awg0 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print \$2}' || echo 'нет'" 10 2>/dev/null || echo 'нет')"

    mtu_awg1="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "ip link show awg1 2>/dev/null | grep -o 'mtu [0-9]*' | awk '{print \$2}' || echo 'нет'" 10 2>/dev/null || echo 'нет')"

    handshakes="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "awg show all latest-handshakes 2>/dev/null | awk '{now=systime(); age=now-\$3; if(\$3>0) printf \"  peer %s: %ds назад\n\",\$2,age}' || echo '  нет данных'" 10 2>/dev/null || echo '  нет данных')"

    rmem="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.core.rmem_max 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"
    wmem="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.core.wmem_max 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"
    congestion="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"
    backlog="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.core.netdev_max_backlog 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"
    fastopen="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.ipv4.tcp_fastopen 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"
    slow_start="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"
    mtu_probe="$(ssh_exec "$ip" "$user" "$key" "$pass" \
        "sysctl -n net.ipv4.tcp_mtu_probing 2>/dev/null || echo 'N/A'" 10 2>/dev/null || echo 'N/A')"

    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    printf "│  %-59s│\n" "${label} (${ip})"
    echo "├─────────────────────────────────────────────────────────────┤"
    printf "│  %-35s %-23s│\n" "Ping 8.8.8.8 (min/avg/max/jitter ms)" "${ping_summary}"
    printf "│  %-35s %-23s│\n" "Скорость загрузки (МБ/с)" "${speed_mb}"
    echo "├─────────────────────────────────────────────────────────────┤"
    printf "│  %-35s %-23s│\n" "MTU awg0" "${mtu_awg0}"
    printf "│  %-35s %-23s│\n" "MTU awg1" "${mtu_awg1}"
    echo "├─────────────────────────────────────────────────────────────┤"
    printf "│  %-35s %-23s│\n" "rmem_max" "${rmem}"
    printf "│  %-35s %-23s│\n" "wmem_max" "${wmem}"
    printf "│  %-35s %-23s│\n" "tcp_congestion_control" "${congestion}"
    printf "│  %-35s %-23s│\n" "netdev_max_backlog" "${backlog}"
    printf "│  %-35s %-23s│\n" "tcp_fastopen" "${fastopen}"
    printf "│  %-35s %-23s│\n" "tcp_slow_start_after_idle" "${slow_start}"
    printf "│  %-35s %-23s│\n" "tcp_mtu_probing" "${mtu_probe}"
    echo "├─────────────────────────────────────────────────────────────┤"
    echo "│  WireGuard handshakes:                                      │"
    while IFS= read -r line; do
        printf "│  %-59s│\n" "${line}"
    done <<< "${handshakes}"
    echo "└─────────────────────────────────────────────────────────────┘"
}

# ── Замер задержки туннеля VPS1→VPS2 ─────────────────────────────────────────
benchmark_tunnel() {
    local vps1_ip="$1" vps1_user="$2" vps1_key="$3" vps1_pass="$4"

    log "Замер задержки туннеля VPS1 → VPS2 (10.8.0.2)..."

    local tunnel_ping
    tunnel_ping="$(ssh_exec "$vps1_ip" "$vps1_user" "$vps1_key" "$vps1_pass" \
        "ping -c 10 -q 10.8.0.2 2>&1 | tail -3" 35 2>/dev/null || echo 'N/A')"

    local tunnel_summary
    tunnel_summary="$(echo "$tunnel_ping" | grep -oE '[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+' | head -1 || echo 'N/A')"

    echo ""
    echo "┌─────────────────────────────────────────────────────────────┐"
    echo "│  Туннель VPS1 → VPS2 (10.8.0.2)                            │"
    echo "├─────────────────────────────────────────────────────────────┤"
    printf "│  %-35s %-23s│\n" "Ping (min/avg/max/jitter ms)" "${tunnel_summary}"
    echo "└─────────────────────────────────────────────────────────────┘"
}

# ── Основной поток ────────────────────────────────────────────────────────────
step "Benchmark VPN серверов"

[[ "${DO_VPS1}" == "true" ]] && benchmark_server "VPS1" "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
[[ "${DO_VPS2}" == "true" ]] && benchmark_server "VPS2" "$VPS2_IP" "$VPS2_USER" "$VPS2_KEY" "${VPS2_PASS:-}"

if [[ "${DO_VPS1}" == "true" && "${DO_VPS2}" == "true" ]]; then
    benchmark_tunnel "$VPS1_IP" "$VPS1_USER" "$VPS1_KEY" "$VPS1_PASS"
fi

echo ""
ok "Benchmark завершён"
